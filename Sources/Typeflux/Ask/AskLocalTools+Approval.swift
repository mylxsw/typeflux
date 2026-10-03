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
        case "artifact":
            target = try artifactBinding(args, conversationId: conversationId)
            definition = Self.artifactDefinition
            summary = target.id + " / " + (args["entry"] as? String ?? "")
        case "project_files":
            target = try projectBinding(args, conversationId: conversationId)
            definition = try Self.projectDefinition(roots: fileTools(conversationId: conversationId).roots)
            summary = (target.path ?? "") + " / " + target.id + " / " + (args["action"] as? String ?? "")
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
        case "computer", "browser":
            definition = Self.builtins.first { $0.name == call.function.name }
            target = try await automationBinding(call.function.name, args: args, conversationId: conversationId)
            summary = target.id + (target.domain.map { " / " + $0 } ?? "")
            if let destination = args["url"] as? String { summary += " → " + destination }
            // An observation is single-use evidence, never a reusable authorization.
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
        case "artifact", "project_files":
            return try executeApprovedWorkspaceTool(call.function.name, args: args,
                                                    conversationId: conversationId, target: binding.target)
        case "computer", "browser":
            return try await executeAutomation(call.function.name, args: args, conversationId: conversationId,
                                               approved: binding.target, authorize: authorize)
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

    private func executeApprovedWorkspaceTool(_ name: String, args: [String: Any],
                                              conversationId: String, target: AskExecutionTarget) throws -> AskLocalToolOutput {
        // No suspension between live authorization, descriptor validation and publication.
        if name == "artifact" {
            guard try artifactBinding(args, conversationId: conversationId) == target else {
                throw AskProjectError.conflict
            }
            return try executeArtifact(args, conversationId: conversationId)
        }
        guard try projectBinding(args, conversationId: conversationId) == target else {
            throw AskProjectError.conflict
        }
        return try executeProject(args, conversationId: conversationId)
    }

}
