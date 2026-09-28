import AppKit

struct AskLocalToolOutput: Sendable {
    var content: String
    var image: String?
}

@MainActor
protocol AskToolExecuting {
    func bindConversation(_ id: String)
    func definitions() async -> [AskToolDefinition]
    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput
}

/// All calls, including MCP calls, pass through the conversation's explicit
/// approval and persistent execution journal before reaching this executor.
@MainActor
final class AskLocalTools: AskToolExecuting {
    private let registry: MCPRegistry
    private var mcpTools: [String: any AgentTool] = [:]
    var targetApplication: NSRunningApplication?
    private var capturedDisplays: [String: CGDirectDisplayID] = [:]
    private var targets: [String: NSRunningApplication] = [:]
    private let runner: any ProcessCommandRunning

    init(registry: MCPRegistry, runner: any ProcessCommandRunning = ProcessCommandRunner()) {
        self.registry = registry; self.runner = runner
    }

    func bindConversation(_ id: String) { targets[id] = targetApplication }

    func definitions() async -> [AskToolDefinition] {
        await registry.connectAutoConnectServers()
        var result = Self.builtins
        mcpTools = [:]
        var schemaBytes = 0
        for tool in await registry.allMCPTools() {
            let name = "mcp_" + tool.definition.name
            guard name.count <= 64, mcpTools[name] == nil,
                  name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  let schema = try? JSONSerialization.data(withJSONObject: tool.definition.inputSchema.jsonObject, options: .sortedKeys),
                  schema.count <= 32000, schemaBytes + schema.count <= 500000 else { continue }
            schemaBytes += schema.count
            mcpTools[name] = tool
            result.append(.init(name: name, description: String(tool.definition.description.prefix(2000)), parameters: JSONValue(data: schema)))
            if result.count == 64 { break }
        }
        return result
    }

    static let builtins: [AskToolDefinition] = [
        definition("computer", description: "Observe or control the user's desktop after approval. Screenshot first; click coordinates are fractions (0...1) of that display. Inspect again after acting. Keys: return, tab, escape, backspace, up, down, left, right. One action per call.", properties: [
            "action": ["type": "string", "enum": ["screenshot", "click", "type", "key", "scroll"]],
            "x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
            "text": ["type": "string"], "key": ["type": "string"], "amount": ["type": "integer", "minimum": -10, "maximum": 10]
        ]),
        definition("browser", description: "Read or interact with the original Safari or Chrome tab after approval. Actions: read returns URL, visible text and links; open navigates to an HTTP(S) URL; click/fill use a CSS selector. One action per call. Never claim unavailable browser access succeeded.", properties: [
            "action": ["type": "string", "enum": ["read", "open", "click", "fill"]], "url": ["type": "string"],
            "selector": ["type": "string"], "text": ["type": "string"]
        ])
    ]

    private static func definition(_ name: String, description: String, properties: [String: Any]) -> AskToolDefinition {
        let schema: [String: Any] = ["type": "object", "properties": properties, "required": ["action"], "additionalProperties": false]
        return .init(name: name, description: description, parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    func execute(_ call: AskToolCall, conversationId: String) async throws -> AskLocalToolOutput {
        try Task.checkCancellation()
        if let tool = mcpTools[call.function.name] {
            let output = try await tool.execute(arguments: call.function.arguments)
            try Task.checkCancellation()
            return .init(content: String(output.prefix(60000)))
        }
        let args = try Self.arguments(call.function.arguments)
        switch call.function.name {
        case "computer": return try await computer(args, target: targets[conversationId], conversationId: conversationId)
        case "browser": return try await browser(args, target: targets[conversationId])
        default: throw AskLocalError.message(L("ask.tool.unavailable"))
        }
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

    private func computer(_ args: [String: Any], target: NSRunningApplication?, conversationId: String) async throws -> AskLocalToolOutput {
        if args["action"] as? String == "screenshot" {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let shot = try await AskContextCapture.screenshot(displayId: id)
            capturedDisplays[conversationId] = shot.displayId
            return .init(content: "Current screen: \(shot.width) × \(shot.height). Click coordinates are normalized from the top-left (0,0) to bottom-right (1,1).", image: shot.dataURL)
        }
        guard AXIsProcessTrusted() else { throw AskLocalError.message(L("ask.tool.accessibility")) }
        try activateTarget(target)
        // Allow the window server to focus the approved application before events.
        try await Task.sleep(for: .milliseconds(200))
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target?.processIdentifier else {
            throw AskLocalError.message(L("ask.tool.targetMissing"))
        }
        switch args["action"] as? String {
        case "click":
            guard let display = capturedDisplays[conversationId], let x = args["x"] as? Double, let y = args["y"] as? Double,
                  x.isFinite, y.isFinite, (0 ... 1).contains(x), (0 ... 1).contains(y) else { throw AskLocalError.message(L("ask.tool.invalid")) }
            let bounds = CGDisplayBounds(display)
            let point = CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
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
            let keys: [String: CGKeyCode] = ["return": 36, "tab": 48, "escape": 53, "backspace": 51, "up": 126, "down": 125, "left": 123, "right": 124]
            guard let name = args["key"] as? String, let key = keys[name] else { throw AskLocalError.message(L("ask.tool.invalid")) }
            for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap) }
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

    private func browser(_ args: [String: Any], target: NSRunningApplication?) async throws -> AskLocalToolOutput {
        guard let bundle = target?.bundleIdentifier,
              ["com.apple.Safari", "com.google.Chrome"].contains(bundle) else {
            throw AskLocalError.message(L("ask.tool.browserUnsupported"))
        }
        return try await executeBrowser(args, bundle: bundle)
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
        case "click", "fill":
            guard let selector = args["selector"] as? String, selector.count <= 2000 else { throw AskLocalError.message(L("ask.tool.invalid")) }
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
