import Foundation

extension AskLocalTools {
    func bindExecution(ownerId: String, conversationId: String, runId: String, deviceId: String, persistent: Bool) {
        commandDeviceId = deviceId
        commandPersistence[conversationId] = persistent
        bindExecution(ownerId: ownerId, conversationId: conversationId, runId: runId)
    }

    func commandScope(_ conversationId: String) throws -> AskCommandJobScope {
        guard let commandJobs else { throw AskCommandJobError.unavailable }
        return try commandJobs.scope(owner: owner(), conversation: conversationId)
    }

    func commandJobBinding(_ call: AskToolCall, conversationId: String) throws -> AskToolBinding {
        let request = try AskCommandJobRequest.validated(Self.jsonArguments(call.function.arguments))
        let scope = try commandScope(conversationId)
        guard let commandJobs else { throw AskCommandJobError.unavailable }
        if request.action == "start" {
            guard settings?.askCodeExecutionEnabled == true else { throw AskCommandJobError.unavailable }
        } else {
            _ = try commandJobs.status(request.handle, scope: scope)
        }
        let summary = request.action == "start" ? request.command + "\n" + L("ask.commandJob.deadline", request.timeout)
            + "\n" + L("ask.commandJob.lifetime") : L("ask.commandJob." + request.action)
        return .init(target: .init(kind: "workspace", id: "host-command:" + conversationId,
                                   version: AskToolPolicy
                                       .digest(scope.owner + scope.run + scope.device + scope.generation.uuidString)),
                     toolVersion: AskToolPolicy.digest(AskCommandJobRequest.definition.parameters.data),
                     summary: summary,
                     allowsReuse: false)
    }

    func executeCommandJob(_ call: AskToolCall, conversationId: String,
                           authorize: () throws -> Void) async throws -> AskLocalToolOutput {
        let request = try AskCommandJobRequest.validated(Self.jsonArguments(call.function.arguments))
        let scope = try commandScope(conversationId)
        guard let commandJobs else { throw AskCommandJobError.unavailable }
        try authorize()
        let content: String
        switch request.action {
        case "start":
            let status = try await commandJobs.start(request, scope: scope, invocationID: call.id,
                                                     deadline: executionDeadlines[conversationId], workspace: {
                                                         if let workspaces = self
                                                             .workspaces {
                                                             return try await workspaces.ensure(
                                                                 owner: scope.owner,
                                                                 conversationId: scope.conversation
                                                             )
                                                         }
                                                         return nil
                                                     }, authorize: {
                                                         guard self.settings?.askCodeExecutionEnabled == true,
                                                               self.owner() == scope.owner,
                                                               try self.commandScope(conversationId) == scope
                                                         else { throw AskCommandJobError.unavailable }
                                                         try authorize()
                                                     }, admission: { [weak self] in
                                                         guard let self, settings?.askCodeExecutionEnabled == true,
                                                               owner() == scope.owner else {
                                                             throw AskCommandJobError.unavailable
                                                         }
                                                     })
            content = try Self.terminalJSON(status)
        case "status": content = try Self.terminalJSON(commandJobs.status(request.handle, scope: scope))
        case "logs": content = try Self.terminalJSON(commandJobs.logs(
                request.handle,
                scope: scope,
                stream: request.stream,
                offset: request.offset,
                limit: request.limit
            ))
        case "stop": content = try Self.terminalJSON(commandJobs.stop(request.handle, scope: scope))
        default: throw AskCommandJobError.invalid
        }
        // A successful start receipt means admission, never verified command completion.
        return .init(content: content, outcome: .init(status: "ok", effectVerified: false))
    }

    func observeCommandRun(ownerId: String, conversationId: String, runId: String?, active: Bool) {
        commandJobs?.observeRun(owner: ownerId, conversation: conversationId, run: runId, active: active)
    }

    func shutdownCommandJobs() async {
        await commandJobs?.shutdown()
    }
}
