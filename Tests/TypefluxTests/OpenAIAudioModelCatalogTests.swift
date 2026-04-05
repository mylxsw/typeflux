import XCTest

@testable import Typeflux

final class OpenAIAudioModelCatalogTests: XCTestCase {
    func testResolvedWhisperEndpointFallsBackToOpenAIDefault() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperEndpoint("  "),
            "https://api.openai.com/v1/audio/transcriptions"
        )
    }

    func testResolvedWhisperModelFallsBackToOpenAIDefault() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(" "),
            "gpt-4o-transcribe"
        )
    }

    func testResolvedWhisperModelFallsBackToXAIDefaultForXAIEndpoint() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(" ", endpoint: "https://api.x.ai/v1/audio/transcriptions"),
            "whisper-1"
        )
    }

    func testResolvedWhisperModelFallsBackToGroqDefaultForGroqEndpoint() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(" ", endpoint: "https://api.groq.com/openai/v1/audio/transcriptions"),
            "whisper-large-v3-turbo"
        )
    }

    func testWhisperBuiltInOptionsMatchSupportedValues() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.whisperModels,
            ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
        )
    }

    func testXAIWhisperBuiltInOptionsMatchSupportedValues() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.suggestedWhisperModels(forEndpoint: "https://api.x.ai/v1/audio/transcriptions"),
            ["whisper-1"]
        )
    }

    func testGroqWhisperBuiltInOptionsPreferTurboByDefault() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.groqWhisperModels,
            ["whisper-large-v3-turbo", "whisper-large-v3"]
        )
    }

    func testGroqSuggestedWhisperOptionsUseGroqCatalog() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.suggestedWhisperModels(forEndpoint: "https://api.groq.com/openai/v1/audio/transcriptions"),
            ["whisper-large-v3-turbo", "whisper-large-v3"]
        )
    }

    func testWhisperStreamingSupportDisablesStreamForWhisperOne() {
        XCTAssertFalse(
            OpenAIAudioModelCatalog.supportsWhisperStreaming(
                model: "whisper-1",
                endpoint: "https://api.openai.com/v1/audio/transcriptions"
            )
        )
    }

    func testWhisperStreamingSupportDisablesStreamForGroqWhisperEndpoints() {
        XCTAssertFalse(
            OpenAIAudioModelCatalog.supportsWhisperStreaming(
                model: "whisper-large-v3-turbo",
                endpoint: "https://api.groq.com/openai/v1/audio/transcriptions"
            )
        )
    }

    func testWhisperStreamingSupportAllowsOpenAITranscribeModels() {
        XCTAssertTrue(
            OpenAIAudioModelCatalog.supportsWhisperStreaming(
                model: "gpt-4o-transcribe",
                endpoint: "https://api.openai.com/v1/audio/transcriptions"
            )
        )
    }

    func testMultimodalBuiltInModelsMatchSupportedValues() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.multimodalModels,
            ["gpt-4o-audio-preview", "gpt-4o-mini-audio-preview", "mimo-v2-omni"]
        )
    }

    func testBuiltInEndpointsMatchConfiguredDefaults() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.whisperEndpoints,
            ["https://api.openai.com/v1/audio/transcriptions"]
        )
        XCTAssertEqual(
            OpenAIAudioModelCatalog.multimodalEndpoints,
            [
                "https://api.openai.com/v1/chat/completions",
                "https://api.xiaomimimo.com/v1/chat/completions",
            ]
        )
    }
}
