import Foundation

enum OpenAIAudioModelCatalog {
    static let defaultWhisperEndpoint = "https://api.openai.com/v1/audio/transcriptions"
    static let defaultWhisperModel = "gpt-4o-transcribe"
    static let xAIWhisperModel = "whisper-1"

    static let whisperEndpoints = [
        defaultWhisperEndpoint
    ]

    static let whisperModels = [
        defaultWhisperModel,
        "gpt-4o-mini-transcribe",
        "whisper-1",
    ]

    static let xAIWhisperModels = [
        xAIWhisperModel
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

    static func suggestedWhisperModels(forEndpoint endpoint: String) -> [String] {
        switch sttEndpointProvider(for: endpoint) {
        case .groq:
            return groqWhisperModels
        case .xai:
            return xAIWhisperModels
        case .openAICompatible:
            return whisperModels
        }
    }

    static func defaultWhisperModel(forEndpoint endpoint: String) -> String {
        suggestedWhisperModels(forEndpoint: endpoint).first ?? defaultWhisperModel
    }

    static func resolvedWhisperModel(_ value: String, endpoint: String = "") -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultWhisperModel(forEndpoint: endpoint) : trimmed
    }

    static func supportsWhisperStreaming(model: String, endpoint: String) -> Bool {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel == "whisper-1" {
            return false
        }

        switch sttEndpointProvider(for: endpoint) {
        case .groq:
            return false
        case .xai, .openAICompatible:
            return true
        }
    }
}

private extension OpenAIAudioModelCatalog {
    enum STTEndpointProvider {
        case openAICompatible
        case groq
        case xai
    }

    static func sttEndpointProvider(for endpoint: String) -> STTEndpointProvider {
        let resolvedEndpoint = resolvedWhisperEndpoint(endpoint)
        guard
            let host = URL(string: resolvedEndpoint)?
                .host?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return .openAICompatible
        }

        if host == "api.groq.com" || host.hasSuffix(".groq.com") {
            return .groq
        }

        if host == "api.x.ai" || host.hasSuffix(".x.ai") {
            return .xai
        }

        return .openAICompatible
    }
}
