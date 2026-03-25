import Foundation

struct LLMRewriteRequest {
    enum Mode {
        case editSelection
        case rewriteTranscript
    }

    let mode: Mode
    let sourceText: String
    let spokenInstruction: String?
    let personaPrompt: String?
}
