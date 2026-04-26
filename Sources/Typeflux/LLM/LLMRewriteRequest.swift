import Foundation

/// Context describing the current app environment when an LLM request is triggered.
/// Passed to `PromptCatalog.appSpecificSystemContext(_:)` so that app-specific prompt
/// logic can be applied. All fields are optional — unavailable values are nil.
struct AppSystemContext {
    let bundleIdentifier: String?
    let appName: String?
    let selectedText: String?
    let isEditable: Bool
    let isFocusedTarget: Bool
    let role: String?
    let windowTitle: String?

    init(snapshot: TextSelectionSnapshot) {
        bundleIdentifier = snapshot.bundleIdentifier
        appName = snapshot.processName
        selectedText = snapshot.selectedText
        isEditable = snapshot.isEditable
        isFocusedTarget = snapshot.isFocusedTarget
        role = snapshot.role
        windowTitle = snapshot.windowTitle
    }
}

struct LLMRewriteRequest {
    enum Mode {
        case editSelection
        case rewriteTranscript
    }

    let mode: Mode
    let sourceText: String
    let spokenInstruction: String?
    let personaPrompt: String?
    let appSystemContext: AppSystemContext?
    let inputContext: InputContextSnapshot?

    init(
        mode: Mode,
        sourceText: String,
        spokenInstruction: String?,
        personaPrompt: String?,
        appSystemContext: AppSystemContext? = nil,
        inputContext: InputContextSnapshot? = nil,
    ) {
        self.mode = mode
        self.sourceText = sourceText
        self.spokenInstruction = spokenInstruction
        self.personaPrompt = personaPrompt
        self.appSystemContext = appSystemContext
        self.inputContext = inputContext
    }
}
