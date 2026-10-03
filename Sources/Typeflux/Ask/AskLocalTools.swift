import AppKit
import ImageIO

struct AskLocalToolOutput: Sendable {
    var content: String
    var image: String?
    /// The tool ran but reported failure, so the model must not treat its output as success.
    var isError = false
    var outcome: AskExecutionOutcome? = nil
}

/// How much a tool call can change. Grants for a conversation cover a tool up to the
/// granted level; destructive calls always ask.
enum AskToolRisk: Int, Comparable, Sendable {
    /// Loads app-provided instructions only; runs without approval.
    case none
    case read, write, destructive

    static func < (lhs: AskToolRisk, rhs: AskToolRisk) -> Bool { lhs.rawValue < rhs.rawValue }
}

@MainActor
protocol AskToolExecuting {
    func bindConversation(_ id: String)
    func risk(of call: AskToolCall) -> AskToolRisk
    /// Tools usable from this conversation; tools that need an unavailable target are omitted.
    func definitions(conversationId: String?) async -> [AskToolDefinition]
    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput
    /// The MCP server behind a tool call, for approvals; nil for built-in tools.
    func mcpServerName(of call: AskToolCall) -> String?
    /// Opens folders the user attached to the `files` tool for one conversation.
    func grantFolders(_ paths: [String], conversationId: String)
}

extension AskToolExecuting {
    func mcpServerName(of _: AskToolCall) -> String? { nil }
    func grantFolders(_: [String], conversationId _: String) {}
}

/// Calls require conversation approval or screenshot consent from the submitted draft.
/// All calls pass through the persistent execution journal before reaching this executor.
@MainActor
final class AskLocalTools: AskToolExecuting {
    private let registry: MCPRegistry
    private var mcpTools: [String: MCPToolAdapter] = [:]
    private var mcpServers: [String: String] = [:]
    var targetApplication: NSRunningApplication?
    private var capturedDisplays: [String: CGDirectDisplayID] = [:]
    private var targets: [String: NSRunningApplication] = [:]
    private let runner: any ProcessCommandRunning
    private let settings: SettingsStore?
    let sandbox: AskCodeSandbox
    let skills: AskSkillLibrary
    private let notes: AskMemoryNoteStore
    let folderGrants: AskFolderGrants
    private let owner: @MainActor () -> String
    /// Running apps, injectable for tests.
    var runningBundleIdentifiers: () -> [String] = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }

    init(registry: MCPRegistry, runner: any ProcessCommandRunning = ProcessCommandRunner(), settings: SettingsStore? = nil,
         sandbox: AskCodeSandbox? = nil, skills: AskSkillLibrary = AskSkillLibrary(), notes: AskMemoryNoteStore = .shared,
         folderGrants: AskFolderGrants = AskFolderGrants(),
         owner: @escaping @MainActor () -> String = { GlobalSoulOwner.currentID }) {
        self.registry = registry; self.runner = runner; self.settings = settings
        self.skills = skills; self.notes = notes; self.folderGrants = folderGrants; self.owner = owner
        self.sandbox = sandbox ?? AskCodeSandbox(readableDirectories: [skills.userDirectory])
    }

    func bindConversation(_ id: String) { targets[id] = targetApplication }

    /// Skills the user has not turned off in settings.
    var enabledSkills: [AskSkill] {
        let disabled = settings?.askDisabledSkills ?? []
        return skills.skills().filter { !disabled.contains($0.name) }
    }

    var fileTools: AskFileTools { AskFileTools(roots: settings?.askFileAccessFolders ?? []) }

    /// Settings folders plus the folders attached to this conversation.
    func fileTools(conversationId: String?) -> AskFileTools {
        var roots = fileTools.roots
        for path in conversationId.map(folderGrants.folders(for:)) ?? [] where !roots.contains(path) { roots.append(path) }
        return AskFileTools(roots: roots)
    }

    func grantFolders(_ paths: [String], conversationId: String) { folderGrants.grant(paths, to: conversationId) }

    /// The bound browser, or a running Safari/Chrome when the question started elsewhere.
    func browserBundle(conversationId: String?) -> String? {
        // An existing conversation only controls the app it was bound to, which is gone after a restart.
        let target = conversationId.map { targets[$0] } ?? targetApplication
        if let bundle = target?.bundleIdentifier, Self.isSupportedBrowser(bundle) { return bundle }
        let running = runningBundleIdentifiers()
        return ["com.apple.Safari", "com.google.Chrome"].first(where: running.contains)
    }

    func definitions(conversationId: String?) async -> [AskToolDefinition] {
        await registry.connectAutoConnectServers()
        var result = Self.builtins.filter { $0.name != "browser" || browserBundle(conversationId: conversationId) != nil }
        if let files = AskFileTools.definition(roots: fileTools(conversationId: conversationId).roots) { result.append(files) }
        if settings?.askCodeExecutionEnabled == true, let code = sandbox.definition() { result.append(code) }
        if let skill = skills.definition(enabledSkills) { result.append(skill) }
        result.append(AskMemoryNoteStore.definition)
        mcpTools = [:]
        mcpServers = [:]
        var schemaBytes = result.reduce(0) { $0 + $1.parameters.data.count }
        for (name, entry) in Self.mcpToolNames(await registry.registeredTools()) {
            let tool = entry.tool
            guard mcpTools[name] == nil,
                  let schema = try? JSONSerialization.data(withJSONObject: tool.definition.inputSchema.jsonObject, options: .sortedKeys),
                  schema.count <= 32000, schemaBytes + schema.count <= 500000 else { continue }
            schemaBytes += schema.count
            mcpTools[name] = tool
            mcpServers[name] = entry.serverName
            result.append(.init(name: name, description: String(tool.definition.description.prefix(2000)), parameters: JSONValue(data: schema)))
            if result.count == 64 { break }
        }
        return result
    }

    func mcpServerName(of call: AskToolCall) -> String? { mcpServers[call.function.name] }

    /// MCP tools follow their annotations; per the MCP specification an unannotated
    /// tool may be destructive, so it keeps asking every time.
    func risk(of call: AskToolCall) -> AskToolRisk {
        if let tool = mcpTools[call.function.name] {
            let hints = tool.toolDef.annotations
            if hints?.readOnlyHint == true { return .read }
            return hints?.destructiveHint == false ? .write : .destructive
        }
        return Self.builtinRisk(call)
    }

    nonisolated static func builtinRisk(_ call: AskToolCall) -> AskToolRisk {
        let args = (try? jsonArguments(call.function.arguments)) ?? [:]
        let action = args["action"] as? String ?? ""
        switch (call.function.name, action) {
        case ("skill", _): return .none
        case ("computer", "screenshot"), ("computer", "inspect"), ("computer", "wait"),
             ("browser", "read"), ("browser", "snapshot"), ("memory", "list"): return .read
        case ("files", _): return AskFileTools.risk(action: action)
        case ("computer", _), ("browser", _), ("run_code", _), ("memory", _): return .write
        default: return .destructive
        }
    }

    nonisolated static func isSupportedBrowser(_ bundleIdentifier: String?) -> Bool {
        ["com.apple.Safari", "com.google.Chrome"].contains(bundleIdentifier ?? "")
    }

    /// `mcp_<tool>` when the tool name is unique; otherwise the server name qualifies it.
    /// Names that are invalid or still collide are skipped rather than shadowing another tool.
    nonisolated static func mcpToolNames(_ tools: [MCPRegisteredTool]) -> [(String, MCPRegisteredTool)] {
        var counts: [String: Int] = [:]
        for entry in tools { counts[entry.tool.toolDef.name, default: 0] += 1 }
        var used = Set<String>()
        var result: [(String, MCPRegisteredTool)] = []
        for entry in tools {
            let toolName = entry.tool.toolDef.name
            let name = counts[toolName] == 1
                ? "mcp_" + toolName
                : "mcp_" + serverSlug(entry.serverName, id: entry.serverId) + "_" + toolName
            guard name.count <= 64, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  used.insert(name).inserted else { continue }
            result.append((name, entry))
        }
        return result
    }

    nonisolated static func serverSlug(_ name: String, id: UUID) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let mapped = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let slug = mapped.split(separator: "_").joined(separator: "_").prefix(20)
        return slug.isEmpty ? String(id.uuidString.prefix(8)).lowercased() : String(slug)
    }

    static let builtins: [AskToolDefinition] = [
        definition("computer", description: """
        Observe or control the user's desktop after approval, one action per call. Start with screenshot or inspect \
        (inspect lists the target app's accessibility elements with click coordinates). Coordinates are fractions \
        (0...1) of the last captured display. Actions: click, double_click, right_click, drag (x,y to to_x,to_y), type, \
        key (return, tab, escape, backspace, delete, arrows, home, end, pageup, pagedown, space, f1-f12), hotkey \
        (e.g. "cmd+c", "cmd+shift+t"), scroll, wait (seconds up to 5). Verify with screenshot or inspect after acting.
        """, properties: [
            "action": ["type": "string", "enum": ["screenshot", "inspect", "click", "double_click", "right_click", "drag", "type", "key", "hotkey", "scroll", "wait"]],
            "x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
            "to_x": ["type": "number", "minimum": 0, "maximum": 1], "to_y": ["type": "number", "minimum": 0, "maximum": 1],
            "text": ["type": "string"], "key": ["type": "string"], "keys": ["type": "string"],
            "amount": ["type": "integer", "minimum": -10, "maximum": 10], "seconds": ["type": "number", "minimum": 0, "maximum": 5]
        ]),
        definition("browser", description: """
        Read or interact with the front Safari or Chrome tab after approval, one action per call. read returns URL, \
        visible text and links; snapshot lists interactive elements with numeric refs; click/fill take a ref from the \
        latest snapshot (or a CSS selector); open navigates to an http(s) URL; back goes back; scroll moves by screens. \
        Read or snapshot again to verify. Never claim unavailable browser access succeeded.
        """, properties: [
            "action": ["type": "string", "enum": ["read", "snapshot", "open", "click", "fill", "back", "scroll"]], "url": ["type": "string"],
            "selector": ["type": "string"], "ref": ["type": "integer", "minimum": 1], "text": ["type": "string"],
            "amount": ["type": "integer", "minimum": -10, "maximum": 10]
        ])
    ]

    private static func definition(_ name: String, description: String, properties: [String: Any]) -> AskToolDefinition {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": ["action"], "additionalProperties": false]
        return .init(name: name, description: description, parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        try Task.checkCancellation()
        if let tool = mcpTools[call.function.name] {
            let output = try await tool.call(arguments: call.function.arguments)
            try Task.checkCancellation()
            // Decoding and re-encoding a tool image must not block the main actor.
            return await Task.detached(priority: .userInitiated) { Self.output(from: output) }.value
        }
        let args = try Self.jsonArguments(call.function.arguments)
        switch call.function.name {
        case "computer":
            return try await computer(try Self.arguments(call.function.arguments), target: targets[conversationId], conversationId: conversationId)
        case "browser":
            let args = try Self.arguments(call.function.arguments)
            guard let bundle = browserBundle(conversationId: conversationId) else { throw AskLocalError.message(L("ask.tool.browserUnsupported")) }
            return try await executeBrowser(args, bundle: bundle)
        case "files":
            let files = fileTools(conversationId: conversationId)
            let output = try await Task.detached(priority: .userInitiated) { try files.execute(args) }.value
            return .init(content: output)
        case "run_code":
            guard settings?.askCodeExecutionEnabled == true,
                  let language = (args["language"] as? String).flatMap(AskCodeSandbox.Language.init(rawValue:)),
                  let code = args["code"] as? String, !code.isEmpty else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let sandbox = sandbox
            let timeout = args["timeout_seconds"] as? Int ?? AskCodeSandbox.defaultTimeout
            let execution = try await sandbox.run(language, code: code, conversationId: conversationId, timeout: timeout)
            let workspace = try sandbox.workspace(for: conversationId).path
            return .init(content: AskCodeSandbox.report(execution, workspace: workspace), image: execution.image,
                         isError: execution.timedOut || execution.exitCode != 0)
        case "skill":
            guard let name = args["name"] as? String else { throw AskLocalError.message(L("ask.tool.invalid")) }
            guard !(settings?.askDisabledSkills.contains(name) ?? false) else { throw AskLocalError.message(L("ask.skills.missing")) }
            return .init(content: try skills.load(name))
        case "memory":
            return .init(content: try notes.execute(args, owner: owner()))
        default: throw AskLocalError.message(L("ask.tool.unavailable"))
        }
    }

    /// Retains ordered typed content, with a conservative legacy projection.
    nonisolated static func output(from result: MCPToolsCallResult) -> AskLocalToolOutput {
        AskTypedContent.output(from: result)
    }

    /// Re-encodes a tool image as a JPEG within the limits the Ask server accepts.
    nonisolated static func jpegDataURL(base64: String) -> String? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
              jpeg.count <= 2_000_000 else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    nonisolated static func jsonArguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8), let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return args
    }

    nonisolated static func arguments(_ value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8),
              let args = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = args["action"] as? String, !action.isEmpty else {
            throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return args
    }

    private func activateTarget(_ target: NSRunningApplication?) throws {
        guard let app = target, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw AskLocalError.message(L("ask.tool.targetMissing"))
        }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func displayBounds(_ conversationId: String) -> CGRect? {
        capturedDisplays[conversationId].map { CGDisplayBounds($0) }
    }

    private func computer(_ args: [String: Any], target: NSRunningApplication?, conversationId: String) async throws -> AskLocalToolOutput {
        let action = args["action"] as? String ?? ""
        switch action {
        case "screenshot":
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let shot = try await AskContextCapture.screenshot(displayId: id)
            capturedDisplays[conversationId] = shot.displayId
            return .init(content: "Current screen: \(shot.width) × \(shot.height). Click coordinates are normalized from the top-left (0,0) to bottom-right (1,1).", image: shot.dataURL)
        case "wait":
            let seconds = min(5, max(0, (args["seconds"] as? Double) ?? Double(args["seconds"] as? Int ?? 1)))
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return .init(content: "Waited \(seconds) s.")
        case "inspect":
            guard AXIsProcessTrusted() else { throw AskLocalError.message(L("ask.tool.accessibility")) }
            guard let app = target, !app.isTerminated, let root = AskDesktopActions.snapshot(pid: app.processIdentifier) else {
                throw AskLocalError.message(L("ask.tool.targetMissing"))
            }
            // Clicks after inspect use the display that shows the window.
            if let frame = root.frame {
                var display: CGDirectDisplayID = 0, count: UInt32 = 0
                if CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count) == .success, count > 0 {
                    capturedDisplays[conversationId] = display
                }
            }
            let bounds = displayBounds(conversationId) ?? CGDisplayBounds(CGMainDisplayID())
            return .init(content: "Accessibility elements of \(app.localizedName ?? "the app") (click coordinates as @(x, y)):\n" +
                         String(AskDesktopActions.describe(root, display: bounds).prefix(60000)))
        default:
            break
        }
        guard AXIsProcessTrusted() else { throw AskLocalError.message(L("ask.tool.accessibility")) }
        try activateTarget(target)
        // Allow the window server to focus the approved application before events.
        try await Task.sleep(for: .milliseconds(200))
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier else {
            throw AskLocalError.message(L("ask.tool.targetMissing"))
        }
        func point(_ xKey: String, _ yKey: String) throws -> CGPoint {
            guard let bounds = displayBounds(conversationId), let x = args[xKey] as? Double ?? (args[xKey] as? Int).map(Double.init),
                  let y = args[yKey] as? Double ?? (args[yKey] as? Int).map(Double.init),
                  let point = AskDesktopActions.point(x: x, y: y, in: bounds) else { throw AskLocalError.message(L("ask.tool.invalid")) }
            return point
        }
        func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clicks)
            event?.post(tap: .cghidEventTap)
        }
        func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        }
        switch action {
        case "click":
            let target = try point("x", "y")
            post(.leftMouseDown, at: target); post(.leftMouseUp, at: target)
        case "double_click":
            let target = try point("x", "y")
            for clicks in [Int64(1), 2] { post(.leftMouseDown, at: target, clicks: clicks); post(.leftMouseUp, at: target, clicks: clicks) }
        case "right_click":
            let target = try point("x", "y")
            post(.rightMouseDown, at: target, button: .right); post(.rightMouseUp, at: target, button: .right)
        case "drag":
            let from = try point("x", "y"), to = try point("to_x", "to_y")
            post(.leftMouseDown, at: from)
            for step in 1 ... 12 {
                try Task.checkCancellation()
                let t = CGFloat(step) / 12
                post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                try await Task.sleep(for: .milliseconds(15))
            }
            post(.leftMouseUp, at: to)
        case "type":
            guard let text = args["text"] as? String, text.utf16.count <= 10000 else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let chars = Array(text.utf16)
            var offset = 0
            while offset < chars.count {
                try Task.checkCancellation()
                var end = min(chars.count, offset + 20)
                if end < chars.count, (0xD800 ... 0xDBFF).contains(chars[end - 1]) { end -= 1 }
                let slice = Array(chars[offset ..< end])
                offset = end
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    slice.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: $0.baseAddress!) }
                    event?.post(tap: .cghidEventTap)
                }
                await Task.yield()
            }
        case "key":
            guard let name = (args["key"] as? String)?.lowercased(), let key = AskDesktopActions.keyCodes[name] else { throw AskLocalError.message(L("ask.tool.invalid")) }
            press(key)
        case "hotkey":
            guard let shortcut = AskDesktopActions.parseHotkey(args["keys"] as? String ?? args["key"] as? String ?? "") else {
                throw AskLocalError.message(L("ask.tool.invalid"))
            }
            press(shortcut.key, flags: shortcut.flags)
        case "scroll":
            guard let amount = args["amount"] as? Int, (-10 ... 10).contains(amount) else { throw AskLocalError.message(L("ask.tool.invalid")) }
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        default: throw AskLocalError.message(L("ask.tool.invalid"))
        }
        return .init(content: "Action dispatched. Inspect the screen to verify the outcome.")
    }

    nonisolated static func javascriptLiteral(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }
    nonisolated static func appleScriptLiteral(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    func executeBrowser(_ args: [String: Any], bundle: String) async throws -> AskLocalToolOutput {
        let source = try Self.browserScript(args, bundle: bundle)
        do {
            let output = try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", source])
            try Task.checkCancellation()
            return .init(content: String(output.stdout.prefix(60000)))
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw AskLocalError.message(L("ask.tool.browserPermission"))
        }
    }
    /// Numbers visible interactive elements so later calls can address them by ref.
    nonisolated static let snapshotScript = """
    (()=>{document.querySelectorAll('[data-typeflux-ref]').forEach(e=>e.removeAttribute('data-typeflux-ref'));\
    const all=[...document.querySelectorAll('a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[contenteditable=true]')];\
    const visible=all.filter(e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'}).slice(0,200);\
    return JSON.stringify({url:location.href,title:document.title,elements:visible.map((e,i)=>{e.setAttribute('data-typeflux-ref',String(i+1));\
    const name=(e.getAttribute('aria-label')||e.innerText||e.value||e.getAttribute('placeholder')||e.title||e.getAttribute('href')||'').trim().replace(/\\s+/g,' ').slice(0,100);\
    return {ref:i+1,tag:e.tagName.toLowerCase(),role:e.getAttribute('role')||e.type||'',name}})})})()
    """

    nonisolated static func browserScript(_ args: [String: Any], bundle: String) throws -> String {
        guard ["com.apple.Safari", "com.google.Chrome"].contains(bundle) else {
            throw AskLocalError.message(L("ask.tool.browserUnsupported"))
        }
        let script: String
        switch args["action"] as? String {
        case "read":
            script = "JSON.stringify({url:location.href,title:document.title,text:document.body.innerText.slice(0,40000),links:Array.from(document.links).slice(0,60).map(a=>({text:a.innerText,url:a.href}))})"
        case "open":
            guard let raw = args["url"] as? String, raw.count <= 4000, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AskLocalError.message(L("ask.tool.invalid")) }
            script = "location.href=\(Self.javascriptLiteral(raw));'Navigation requested'"
        case "snapshot":
            script = snapshotScript
        case "back":
            script = "history.back();'Went back; read or snapshot to verify'"
        case "scroll":
            guard let amount = args["amount"] as? Int, (-10 ... 10).contains(amount) else { throw AskLocalError.message(L("ask.tool.invalid")) }
            script = "window.scrollBy(0,\(amount)*Math.round(innerHeight*0.8));'Scrolled'"
        case "click", "fill":
            // A ref from the latest snapshot, or a CSS selector.
            let selector: String
            if let ref = args["ref"] as? Int, ref > 0 {
                selector = "[data-typeflux-ref=\"\(ref)\"]"
            } else if let css = args["selector"] as? String, !css.isEmpty, css.count <= 2000 {
                selector = css
            } else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let action: String
            if args["action"] as? String == "fill" {
                guard let text = args["text"] as? String, text.count <= 10000 else { throw AskLocalError.message(L("ask.tool.invalid")) }
                action = "e.value=\(Self.javascriptLiteral(text));e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));"
            } else { action = "e.click();" }
            script = "(()=>{const e=document.querySelector(\(Self.javascriptLiteral(selector)));if(!e)return 'Element not found';\(action)return 'Action dispatched; read page to verify';})()"
        default: throw AskLocalError.message(L("ask.tool.invalid"))
        }
        let command = bundle == "com.apple.Safari"
            ? "do JavaScript \(Self.appleScriptLiteral(script)) in front document"
            : "execute active tab of front window javascript \(Self.appleScriptLiteral(script))"
        let source = "with timeout of 20 seconds\ntell application id \(Self.appleScriptLiteral(bundle))\n\(command)\nend tell\nend timeout"
        return source
    }

}
