import Foundation

extension AskConversationModel {
    /// Reject locally known unsupported runs before host-side preflight or control.
    /// Cloud snapshots may omit this server-owned metadata; it never selects an engine.
    func admitAgentCommand(_ value: AskConversation) -> Bool {
        do {
            _ = try AskAgentBinding.resolve(value.run?.agentBinding)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
