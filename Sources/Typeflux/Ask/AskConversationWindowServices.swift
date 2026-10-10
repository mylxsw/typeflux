import Foundation

/// The local stores and window destinations used when wiring a conversation
/// workspace. Supplying them keeps a workspace independent of shared stores.
@MainActor
struct AskConversationWindowServices {
    let tools: AskLocalTools
    let cache: AskConversationCache
    let api: any AskAPI
    let capture: any AskContextCapturing
    let session: () -> (owner: String, token: String)?
    let workflows: AskWorkflowStore
    let wordBook: any AskWordBookStoring
    let notes: any AskNoteStoring
    let wordBookWindow: AskWordBookWindowController
    let notesWindow: AskNotesWindowController
    let resultWindow: AskResultWindowController
    let frameAutosaveName: String
}
