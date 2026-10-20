import Foundation

/// Presentation only: the transcript and running request belong to the conversation model.
struct AskQuickAskSession {
    let generation = UUID()
    let owner: String
    let submitted: AskDraft
    let keyword: AskKeyword
    var conversationId: String?
    var persisted = false
    var handedOff = false
    var stopped = false
    var restoreOnPresentation = false
}
