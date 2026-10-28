import Foundation

extension AskConversationModel {
    nonisolated static let workspaceDraftKey = "chat-workspace"

    /// The current new-chat editor, including an intentional empty state. Recovery
    /// copies are an archive and must not decide what a fresh window displays.
    var workspaceDraftSnapshot: AskDraft? {
        guard FeatureProcess.owns(.chat), workspaceDraftReady else { return nil }
        guard selectedId == nil, draft.temporary != true else { return .followUp }
        return draft
    }
}
