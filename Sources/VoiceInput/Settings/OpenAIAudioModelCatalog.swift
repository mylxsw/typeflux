import Foundation

enum OpenAIAudioModelCatalog {
    static let whisperEndpoints = [
        "https://api.openai.com/v1/audio/transcriptions"
    ]

    static let whisperModels = [
        "gpt-4o-mini-transcribe",
        "whisper-1",
        "gpt-4o-transcribe"
    ]

    static let multimodalEndpoints = [
        "https://api.openai.com/v1/chat/completions"
    ]

    static let multimodalModels = [
        "gpt-4o-mini-audio-preview",
        "gpt-4o-audio-preview",
        "gpt-audio-mini"
    ]

    static func normalizeWhisperEndpoint(_ value: String) -> String {
        normalize(value, allowedValues: whisperEndpoints, defaultValue: whisperEndpoints[0])
    }

    static func normalizeWhisperModel(_ value: String) -> String {
        normalize(value, allowedValues: whisperModels, defaultValue: whisperModels[0])
    }

    static func normalizeMultimodalEndpoint(_ value: String) -> String {
        normalize(value, allowedValues: multimodalEndpoints, defaultValue: multimodalEndpoints[0])
    }

    static func normalizeMultimodalModel(_ value: String) -> String {
        normalize(value, allowedValues: multimodalModels, defaultValue: multimodalModels[0])
    }

    private static func normalize(_ value: String, allowedValues: [String], defaultValue: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return defaultValue }
        return allowedValues.first(where: { $0.caseInsensitiveCompare(trimmedValue) == .orderedSame }) ?? defaultValue
    }
}
