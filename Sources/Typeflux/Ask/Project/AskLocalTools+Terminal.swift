import Foundation

struct AskProjectTerminalReceipt: Codable {
    var process: AskProcessRef
    var status: AskProjectProcessStatus
    var text: String
    var nextCursor: Int64
    var lostBytes: Int64
    var truncated: Bool
    var previewEntry: String?
    var previewResources: [String]?
    var artifacts: [AskArtifactRef]?
    var previewEvidence: AskProjectPreviewEvidence?

    static func decode(_ text: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }
}

extension AskLocalTools {
    nonisolated static var terminalEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }

    static var terminalDefinition: AskToolDefinition {
        let properties: [String: Any] = [
            "action": ["type": "string", "enum": ["start", "input", "status", "output", "stop", "preview"]],
            "workspace_id": ["type": "string"], "expected_version": ["type": "string"],
            "script": ["type": "string"], "arguments": ["type": "array", "items": ["type": "string"]],
            "cwd": ["type": "string"], "timeout_seconds": ["type": "number"],
            "terminal": ["type": "string", "enum": ["pipe", "pty"]], "service": ["type": "boolean"],
            "readiness_timeout_seconds": ["type": "number"], "lease_id": ["type": "string"],
            "text": ["type": "string"], "eof": ["type": "boolean"],
            "entry": ["type": "string"], "resources": ["type": "array", "items": ["type": "string"]]
        ]
        // The fixed schema contains only JSON primitives.
        guard let schema = try? JSONSerialization.data(withJSONObject: [
            "type": "object", "properties": properties, "required": ["action"], "additionalProperties": false
        ], options: .sortedKeys) else { preconditionFailure("Invalid built-in terminal schema") }
        return .init(name: "project_terminal", description: """
        Run a preinstalled CLT Python script in an approved private project copy, offline, single process only.
        No shell, subprocesses, npm/pip or network installation. Start requires workspace_id and expected_version.
        Defaults: cwd '.', arguments [], pipe, timeout_seconds 300, readiness_timeout_seconds 10, service false.
        service true passes listener fd 3 and a nonce readiness contract; scripts must not bind their own socket.
        Every start and input/EOF requires fresh approval. input text is exact UTF-8 (maximum 64 KiB).
        status/output return bounded UTF-8 text, byte cursor, loss/truncation and the actual process exit code.
        Only exited with exitCode 0 is a successful command; starting a service is not task completion.
        preview requires a ready lease, an HTML entry and a complete explicit list of relative resources.
        It captures the actual isolated page, console/errors and screenshot as device artifacts; no HTTP bridge,
        fetch, WebSocket, workers, external resources or native access from the page. Stop releases the process/port.
        """, parameters: JSONValue(data: schema))
    }

    nonisolated static func launchRequest(_ args: [String: Any]) throws -> AskProjectLaunchRequest {
        guard let script = args["script"] as? String else { throw AskProjectRuntimeError.invalidRequest }
        let allowed: Set = ["action", "workspace_id", "expected_version", "script", "arguments", "cwd",
                            "terminal", "timeout_seconds", "readiness_timeout_seconds", "service"]
        guard Set(args.keys).isSubset(of: allowed) else { throw AskProjectRuntimeError.invalidRequest }
        let service: Bool = try terminalValue(args, "service", default: false)
        let request = try AskProjectLaunchRequest(
            script: script, arguments: terminalValue(args, "arguments", default: []),
            cwd: terminalValue(args, "cwd", default: "."),
            terminal: terminalValue(args, "terminal", default: .pipe),
            timeout: terminalValue(args, "timeout_seconds", default: 300),
            servicePort: service ? 0 : nil,
            readinessTimeout: terminalValue(args, "readiness_timeout_seconds", default: 10)
        )
        try AskProjectRuntimePolicy.validate(request)
        return request
    }

    private nonisolated static func terminalValue<T: Decodable>(_ args: [String: Any], _ key: String,
                                                                default fallback: T) throws -> T {
        guard let value = args[key] else { return fallback }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            return try JSONDecoder().decode(T.self, from: data)
        } catch { throw AskProjectRuntimeError.invalidRequest }
    }

    nonisolated static func terminalJSON(_ value: some Encodable) throws -> String {
        guard let text = try String(data: terminalEncoder.encode(value), encoding: .utf8) else {
            throw AskProjectRuntimeError.invalidRequest
        }
        return text
    }

    private func terminalWorkspace(_ args: [String: Any], scope: AskProjectScope) throws -> AskWorkspaceRef {
        guard let id = args["workspace_id"] as? String, let version = args["expected_version"] as? String else {
            throw AskProjectRuntimeError.invalidRequest
        }
        return .init(id: id, ownerId: scope.ownerId, conversationId: scope.conversationId, runId: scope.runId,
                     version: version, cleanup: "user_managed")
    }

    func terminalLease(_ id: String, scope: AskProjectScope) throws -> AskProjectRuntimeLease {
        guard let runtime = projectRuntime,
              let lease = projectLeases[id] else { throw AskProjectRuntimeError.unknownLease }
        _ = try runtime.status(lease, scope: scope)
        return lease
    }

    func terminalBinding(_ call: AskToolCall, conversationId: String) throws -> AskToolBinding {
        let scope = try projectScope(conversationId)
        guard let runtime = projectRuntime else { throw AskProjectRuntimeError.disabled }
        let args = try Self.jsonArguments(call.function.arguments)
        guard let action = args["action"] as? String,
              ["start", "input", "status", "output", "stop", "preview"].contains(action)
        else { throw AskProjectRuntimeError.invalidRequest }
        if action == "start" {
            let request = try Self.launchRequest(args)
            var binding = try runtime.approval(
                for: request,
                workspace: terminalWorkspace(args, scope: scope),
                scope: scope,
                authorizedRoots: fileTools(conversationId: conversationId).roots,
                callId: call.id
            ).binding
            binding.summary = try (binding.target.path ?? "") + "\n" + Self.terminalJSON(request)
            return binding
        }
        guard let id = args["lease_id"] as? String else { throw AskProjectRuntimeError.invalidRequest }
        let lease = try terminalLease(id, scope: scope)
        if action == "input" {
            let data = Data((args["text"] as? String ?? "").utf8)
            guard data.count <= 65536 else { throw AskProjectRuntimeError.inputFull }
            return try runtime.inputApproval(lease, scope: scope, data: data,
                                             eof: args["eof"] as? Bool ?? false, callId: call.id).binding
        }
        return .init(target: .init(kind: "workspace", id: lease.workspace.id,
                                   version: lease.sessionId + ":" + lease.id, path: lease.root),
                     toolVersion: AskProjectRuntimePolicy.version, summary: action + " / " + lease.id)
    }

    func executeTerminal(_ call: AskToolCall, conversationId: String,
                         authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        let scope = try projectScope(conversationId)
        guard let runtime = projectRuntime else { throw AskProjectRuntimeError.disabled }
        let args = try Self.jsonArguments(call.function.arguments)
        let lease: AskProjectRuntimeLease
        let approvals = AskApprovalStore()
        // Derive a narrowly bound D02 single-use grant only inside P02's consumed,
        // revalidated dispatch. The outer grant is checked again after copying.
        if args["action"] as? String == "start" {
            lease = try startTerminal(call, args: args, scope: scope, authorize: authorize)
        } else {
            guard let id = args["lease_id"] as? String else { throw AskProjectRuntimeError.invalidRequest }
            lease = try terminalLease(id, scope: scope)
            try authorize()
            switch args["action"] as? String {
            case "input":
                let data = Data((args["text"] as? String ?? "").utf8), eof = args["eof"] as? Bool ?? false
                let approval = try runtime.inputApproval(lease, scope: scope, data: data, eof: eof, callId: call.id)
                guard let grant = approvals.issue(approval) else { throw AskProjectRuntimeError.approvalRequired }
                try runtime.send(
                    data,
                    eof: eof,
                    lease: lease,
                    scope: scope,
                    callId: call.id,
                    grantId: grant,
                    approvals: approvals
                )
            case "stop": try runtime.stop(lease, scope: scope)
            case "preview":
                guard artifactCreationEnabled, artifactPreviewEnabled,
                      let entry = args["entry"] as? String, let resources = args["resources"] as? [String] else {
                    throw AskArtifactError.previewDisabled
                }
                let preview = try terminalPreview(lease.reference, entry: entry, resources: resources)
                let evidence = try await AskProjectPreviewCapture.capture(
                    preview,
                    store: artifactStore,
                    authorize: authorize
                )
                var receipt = try terminalStatus(lease.reference)
                receipt.previewEntry = entry; receipt.previewResources = resources; receipt.artifacts = evidence
                    .artifacts
                receipt.previewEvidence = evidence
                return try terminalOutput(receipt, artifacts: evidence.artifacts)
            case "status", "output": break
            default: throw AskProjectRuntimeError.invalidRequest
            }
        }
        return try terminalOutput(terminalStatus(lease.reference))
    }

    private func startTerminal(_ call: AskToolCall, args: [String: Any], scope: AskProjectScope,
                               authorize: () throws -> Void) throws -> AskProjectRuntimeLease {
        guard let runtime = projectRuntime else { throw AskProjectRuntimeError.disabled }
        let conversationId = scope.conversationId, approvals = AskApprovalStore()
        let request = try Self.launchRequest(args), workspace = try terminalWorkspace(args, scope: scope)
        let approval = try runtime.approval(for: request, workspace: workspace, scope: scope,
                                            authorizedRoots: fileTools(conversationId: conversationId).roots,
                                            callId: call.id)
        try authorize()
        guard let grant = approvals.issue(approval) else { throw AskProjectRuntimeError.approvalRequired }
        let lease = try runtime.start(request, workspace: workspace, scope: scope,
                                      authorizedRoots: { [weak self] in
                                          self?.fileTools(conversationId: conversationId).roots ?? []
                                      },
                                      callId: call.id, grantId: grant, approvals: approvals, authorize: authorize)
        projectLeases[lease.id] = lease
        return lease
    }

    private func terminalOutput(_ receipt: AskProjectTerminalReceipt,
                                artifacts: [AskArtifactRef] = []) throws -> AskLocalToolOutput {
        let status = receipt.status
        let failed = ![.starting, .running, .ready, .stopped]
            .contains(status.state) && !(status.state == .exited && status.exitCode == 0)
        let content = try Self.terminalJSON(receipt)
        return .init(content: content, isError: failed,
                     outcome: .init(status: failed ? "invalid" : "ok", artifacts: artifacts.isEmpty ? nil : artifacts,
                                    effectVerified: status.state == .exited && status.exitCode == 0))
    }

    func terminalStatus(_ ref: AskProcessRef) throws -> AskProjectTerminalReceipt {
        let scope = try projectScope(ref.conversationId)
        let lease = try terminalLease(ref.id, scope: scope)
        guard ref == lease.reference, let runtime = projectRuntime else { throw AskProjectRuntimeError.unknownLease }
        let status = try runtime.status(lease, scope: scope)
        var buffer = projectOutputBuffers[lease.id] ?? .init()
        let page = try runtime.output(lease, scope: scope, cursor: buffer.cursor)
        let final = ![.starting, .running, .ready].contains(status.state) && page.nextCursor == status.outputBytes
        try buffer.append(page, final: final); projectOutputBuffers[lease.id] = buffer
        return .init(process: ref, status: status, text: buffer.text, nextCursor: buffer.cursor,
                     lostBytes: buffer.lostBytes, truncated: buffer.truncated || status.logTruncated)
    }

    func stopTerminal(_ ref: AskProcessRef) throws {
        let scope = try projectScope(ref.conversationId), lease = try terminalLease(
            ref.id,
            scope: projectScope(ref.conversationId)
        )
        guard ref == lease.reference else { throw AskProjectRuntimeError.unknownLease }
        try projectRuntime?.stop(lease, scope: scope)
    }

    func terminalPreview(_ ref: AskProcessRef, entry: String, resources: [String]) throws -> AskDevelopmentPreview {
        guard artifactPreviewEnabled, let runtime = projectRuntime else { throw AskArtifactError.previewDisabled }
        let scope = try projectScope(ref.conversationId), lease = try terminalLease(ref.id, scope: scope)
        guard ref == lease.reference else { throw AskProjectRuntimeError.unknownLease }
        return try .init(runtime: runtime, lease: lease, scope: scope, entry: entry, paths: resources)
    }

    func cancelProjects(conversationId: String?) {
        for (id, scope) in projectScopes
            where conversationId == nil || conversationId == id {
            projectRuntime?.cancel(scope: scope)
        }
        if conversationId == nil {
            projectScopes = [:]; projectOutputBuffers = [:]
            executionDeadlines = [:]
        } else if let conversationId {
            executionDeadlines[conversationId] = nil
        }
    }

    func cancelProjectRun(_ scope: AskProjectScope) { projectRuntime?.cancel(scope: scope) }
}
