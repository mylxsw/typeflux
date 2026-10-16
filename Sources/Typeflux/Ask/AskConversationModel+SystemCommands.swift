import AppKit

extension AskConversationModel {
    func performSystemCommand(_ command: AskSystemCommand) -> PluginActionOutcome {
        guard confirmSystemCommand(command) else { return .stay }
        finishPluginResult()
        let runner = systemCommandRunner
        Task {
            do {
                try await runner.run(command)
            } catch {
                guard runner.presentsFailures(for: command) else { return }
                let alert = NSAlert()
                alert.messageText = command.title
                alert.informativeText = (error as? AskPluginFailure)?.message ?? error.localizedDescription
                alert.addButton(withTitle: L("common.ok"))
                alert.runModal()
            }
        }
        return .close
    }
}

@MainActor
enum AskSystemCommandConfirmation {
    static func confirm(_ command: AskSystemCommand) -> Bool {
        let alert = NSAlert()
        alert.messageText = command.title
        alert.informativeText = command.confirmationMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("ask.system.run"))
        alert.addButton(withTitle: L("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
