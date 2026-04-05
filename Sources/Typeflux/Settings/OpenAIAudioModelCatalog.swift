import Foundation

enum OpenAIAudioModelCatalog {
    static let defaultWhisperEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    static let defaultWhisperModel = "gpt-4o-transcribe"

    static let whisperEndpoints = [
        defaultWhisperEndpoint
    ]

    static let whisperModels = [
        defaultWhisperModel,
        "gpt-4o-mini-transcribe",
        "whisper-1",
    ]

    static let groqWhisperModels = [
        "whisper-large-v3-turbo",
        "whisper-large-v3",
    ]

    static let multimodalEndpoints = [
        "https://api.openai.com/v1/chat/completions",
        "https://api.xiaomimimo.com/v1/chat/completions",
    ]

    static let multimodalModels = [
        "gpt-4o-audio-preview",
        "gpt-4o-mini-audio-preview",
        "mimo-v2-omni",
    ]

    static func resolvedWhisperEndpoint(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultWhisperEndpoint : trimmed
    }

    static func resolvedWhisperModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultWhisperModel : trimmed
    }
}
