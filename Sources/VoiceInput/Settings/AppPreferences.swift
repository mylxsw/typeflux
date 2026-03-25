import Foundation

enum STTProvider: String, CaseIterable, Codable {
    case whisperAPI
    case appleSpeech

    var displayName: String {
        switch self {
        case .whisperAPI:
            return "Whisper API"
        case .appleSpeech:
            return "Apple Speech"
        }
    }
}

enum LLMProvider: String, CaseIterable, Codable {
    case openAICompatible
    case ollama

    var displayName: String {
        switch self {
        case .openAICompatible:
            return "OpenAI-Compatible"
        case .ollama:
            return "Local Ollama"
        }
    }
}

struct PersonaProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var prompt: String

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
    }
}
