import AppKit

extension AskLocalTools {
    func approvalBinding(for call: AskToolCall, conversationId: String) async throws -> AskToolBinding {
        if let server = mcpIdentities[call.function.name] {
            // Resolve against the live registry, not the definitions cached for a model request.
            guard let entry = Self.mcpToolNames(await registry.registeredTools()).first(where: { $0.0 == call.function.name }),
                  entry.1.serverId == server else { throw AskLocalError.message(L("ask.approval.changed")) }
            return try await registry.approvalBinding(serverId: server, toolName: entry.1.tool.toolDef.name)
        }
        let args = try Self.jsonArguments(call.function.arguments)
        let definition: AskToolDefinition?
        var target: AskExecutionTarget
        var summary: String
        var reusable = false
        switch call.function.name {
        case "files":
            let files = fileTools(conversationId: conversationId)
            definition = AskFileTools.definition(roots: files.roots)
            let path = try files.resolve(args["path"] as? String ?? "", forWriting: args["action"] as? String == "write").path
            target = Self.fileApprovalTarget(path)
            summary = path; reusable = true
        case "memory":
            definition = AskMemoryNoteStore.definition
            target = .init(kind: "workspace", id: "memory:" + owner())
            summary = "Memory / " + owner(); reusable = true
        case "skill":
            definition = skills.definition(enabledSkills)
            target = .init(kind: "workspace", id: "skills:" + owner())
            summary = args["name"] as? String ?? "Skill"
        case "run_code":
            definition = settings?.askCodeExecutionEnabled == true ? sandbox.definition() : nil
            target = .init(kind: "workspace", id: conversationId, version: "analysis-v1")
            summary = (args["language"] as? String ?? "Code") + " / " + conversationId
        case "computer":
            definition = Self.builtins.first { $0.name == "computer" }
            (target, summary) = try computerApprovalTarget(args, conversationId: conversationId)
            // P09 owns reusable observation identity; do not enable reuse from a PID alone.
        case "browser":
            definition = Self.builtins.first { $0.name == "browser" }
            guard let bundle = browserBundle(conversationId: conversationId) else { throw AskLocalError.message(L("ask.tool.targetMissing")) }
            let output = try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", Self.browserApprovalScript(bundle: bundle)])
            let stamp = output.stdout.trimmingCharacters(in: .newlines)
            guard stamp.split(separator: "\u{1f}", omittingEmptySubsequences: false).count == 4 else {
                throw AskLocalError.message(L("ask.tool.targetMissing"))
            }
            target = .init(kind: "browser_tab", id: bundle, version: stamp)
            let url = String(stamp.split(separator: "\u{1f}", omittingEmptySubsequences: false)[2])
            target.domain = URL(string: url)?.host?.lowercased()
            summary = bundle + " / " + url
            if let destination = args["url"] as? String { summary += " → " + destination }
        default: throw AskLocalError.message(L("ask.tool.unavailable"))
        }
        guard let definition else { throw AskLocalError.message(L("ask.tool.unavailable")) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return .init(target: target, toolVersion: AskToolPolicy.digest(try encoder.encode(definition)),
                     summary: summary, allowsReuse: reusable)
    }

    nonisolated static func fileApprovalTarget(_ path: String) -> AskExecutionTarget {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let stamp = [attrs[.systemNumber], attrs[.systemFileNumber], attrs[.size], attrs[.modificationDate]]
            .map { $0.map(String.init(describing:)) ?? "missing" }.joined(separator: ":")
        return .init(kind: "workspace", id: path, version: AskToolPolicy.digest(stamp), path: path)
    }

    func computerApprovalTarget(_ args: [String: Any], conversationId: String) throws -> (AskExecutionTarget, String) {
        let action = args["action"] as? String
        if action == "wait" { return (.init(kind: "workspace", id: conversationId), "Wait") }
        if action == "screenshot" {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            guard let display = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                throw AskLocalError.message(L("ask.tool.targetMissing"))
            }
            return (.init(kind: "desktop_window", id: "display:\(display)"), screen?.localizedName ?? "Display")
        }
        guard let app = targets[conversationId], let launch = approvalProcessStart(app) else {
            throw AskLocalError.message(L("ask.tool.targetMissing"))
        }
        guard let window = focusedApprovalWindow(app.processIdentifier), let frame = approvalWindowFrame(window) else {
            throw AskLocalError.message(L("ask.tool.targetMissing"))
        }
        if approvalWindows[app.processIdentifier].map({ CFEqual($0.0, window) }) != true {
            approvalWindows[app.processIdentifier] = (window, UUID().uuidString)
        }
        let windowID = approvalWindows[app.processIdentifier]!.1
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let stamp = "\(launch.timeIntervalSince1970):\(capturedDisplays[conversationId] ?? 0):\(frame)"
        return (.init(kind: "desktop_window", id: "\(app.processIdentifier):\(windowID)", version: stamp),
                (app.localizedName ?? "Application") + " / " + (title as? String ?? "Window"))
    }

    nonisolated static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated static func windowFrame(_ window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func validateApprovalPoint(_ point: CGPoint, conversationId: String) throws {
        guard let app = targets[conversationId], let window = focusedApprovalWindow(app.processIdentifier),
              approvalWindowFrame(window)?.contains(point) == true else {
            throw AskLocalError.message(L("ask.approval.changed"))
        }
    }

    /// Reads OS-owned window/tab identity and the current document generation.
    /// The dispatch script pins the same tab object instead of following frontmost focus again.
    nonisolated static func browserApprovalScript(bundle: String, expected: String? = nil, actionScript: String? = nil) -> String {
        let safari = bundle == "com.apple.Safari"
        let tab = safari ? "current tab" : "active tab"
        let tabID = safari ? "index of approvedTab" : "id of approvedTab"
        let generation = safari ? "do JavaScript \"String(performance.timeOrigin)\" in approvedTab"
            : "execute approvedTab javascript \"String(performance.timeOrigin)\""
        let check = expected.map { "if stamp is not \(Self.appleScriptLiteral($0)) then error \"Approval target changed\"" } ?? ""
        let action = actionScript.map {
            $0.replacingOccurrences(of: "in front document", with: "in approvedTab")
                .replacingOccurrences(of: "execute active tab of front window", with: "execute approvedTab")
        } ?? "return stamp"
        return """
        with timeout of 20 seconds
        tell application id \(Self.appleScriptLiteral(bundle))
        set approvedWindow to front window
        set approvedTab to \(tab) of approvedWindow
        set documentGeneration to (\(generation))
        set stamp to (id of approvedWindow as text) & (ASCII character 31) & (\(tabID) as text) & (ASCII character 31) & (URL of approvedTab) & (ASCII character 31) & documentGeneration
        \(check)
        \(action)
        end tell
        end timeout
        """
    }

    func executeApproved(_ call: AskToolCall, conversationId: String, binding: AskToolBinding,
                         authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        guard try await approvalBinding(for: call, conversationId: conversationId) == binding else {
            throw AskLocalError.message(L("ask.approval.changed"))
        }
        try Task.checkCancellation()
        try authorize()
        if let server = mcpIdentities[call.function.name] {
            guard let entry = Self.mcpToolNames(await registry.registeredTools()).first(where: { $0.0 == call.function.name }) else {
                throw AskLocalError.message(L("ask.approval.changed"))
            }
            try authorize()
            let result = try await registry.callApproved(serverId: server, toolName: entry.1.tool.toolDef.name,
                                                       arguments: call.function.arguments, binding: binding, authorize: authorize)
            return await Task.detached(priority: .userInitiated) { Self.output(from: result) }.value
        }
        let args = try Self.jsonArguments(call.function.arguments)
        switch call.function.name {
        case "computer":
            return try await computer(args, target: targets[conversationId], conversationId: conversationId, validate: {
                try authorize()
                guard try self.computerApprovalTarget(args, conversationId: conversationId).0 == binding.target else {
                    throw AskLocalError.message(L("ask.approval.changed"))
                }
            }, validatePoint: { point in
                try self.validateApprovalPoint(point, conversationId: conversationId)
            })
        case "browser":
            let script = try Self.browserScript(args, bundle: binding.target.id, approvedDocument: binding.target.version)
            let pinned = Self.browserApprovalScript(bundle: binding.target.id, expected: binding.target.version, actionScript: script)
            let output = try await runner.run(executablePath: "/usr/bin/osascript", arguments: ["-e", pinned])
            try Task.checkCancellation()
            return .init(content: String(output.stdout.prefix(60000)))
        case "files":
            let files = fileTools(conversationId: conversationId)
            return try await Task.detached(priority: .userInitiated) {
                let path = try files.resolve(args["path"] as? String ?? "", forWriting: args["action"] as? String == "write").path
                guard Self.fileApprovalTarget(path) == binding.target else { throw AskLocalError.message(L("ask.approval.changed")) }
                return .init(content: try files.execute(args))
            }.value
        default: return try await execute(call, conversationId: conversationId)
        }
    }
}
