import AppKit

extension AskLocalTools {
    func observationScope(_ tool: String, conversationId: String) -> AskObservationStore.Scope {
        .init(owner: owner(), conversation: conversationId, tool: tool)
    }

    func automationEnvironment(_ conversationId: String) -> AskComputerExecutor.Environment {
        computerEnvironment?(targets[conversationId]) ?? computerProbe.environment(app: targets[conversationId])
    }

    private func observedBrowser(_ args: [String: Any], scope: AskObservationStore.Scope) throws -> String {
        if AskBrowserExecutor.isObservation(args) {
            guard let bundle = browserBundle(conversationId: scope.conversation) else {
                throw AskLocalError.message(L("ask.tool.browserUnsupported"))
            }
            return bundle
        }
        guard browserExecutor.writesEnabled else { throw AskObservationError.disabled }
        // Only the local record can select a write's browser. Never fall back to
        // another running browser because the observed one exited or lost focus.
        guard let bundle = try observationStore.reference(id: args["observation_id"] as? String, scope: scope).browserId
        else { throw AskObservationError.needsObservation }
        return bundle
    }

    func automationBinding(_ tool: String, args: [String: Any], conversationId: String) async throws -> AskExecutionTarget {
        let scope = observationScope(tool, conversationId: conversationId)
        let epoch = conversationEpochs[conversationId]
        let target: AskExecutionTarget
        if tool == "browser" {
            target = try await browserExecutor.binding(args, bundle: observedBrowser(args, scope: scope), scope: scope)
        } else {
            let environment = automationEnvironment(conversationId)
            if args["action"] as? String == "screenshot", (try? environment.target()) == nil {
                target = try screenObservation.target().binding
            } else {
                target = try computerExecutor.binding(args, scope: scope, environment: environment)
            }
        }
        try validateAutomationScope(scope, epoch: epoch)
        return target
    }

    func executeAutomation(_ tool: String, args: [String: Any], conversationId: String,
                           approved: AskExecutionTarget? = nil,
                           authorize: () throws -> Void = {}) async throws -> AskLocalToolOutput {
        let scope = observationScope(tool, conversationId: conversationId)
        let epoch = conversationEpochs[conversationId]
        func check() throws {
            try validateAutomationScope(scope, epoch: epoch)
            try authorize()
            // A synchronous callback can also revoke/rebind the conversation.
            try validateAutomationScope(scope, epoch: epoch)
        }
        if tool == "browser" {
            return try await browserExecutor.execute(args, bundle: observedBrowser(args, scope: scope),
                                                     scope: scope, approved: approved, authorize: check)
        }
        let environment = automationEnvironment(conversationId)
        if args["action"] as? String == "screenshot", (try? environment.target()) == nil {
            return try await screenObservation.execute(store: observationStore, scope: scope,
                                                       approved: approved, authorize: check)
        }
        return try await computerExecutor.execute(args, scope: scope, environment: environment,
                                                  approved: approved, authorize: check)
    }

    private func validateAutomationScope(_ scope: AskObservationStore.Scope, epoch: UUID?) throws {
        guard owner() == scope.owner, conversationEpochs[scope.conversation] == epoch
        else { throw AskObservationError.needsObservation }
    }
}
