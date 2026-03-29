import XCTest
@testable import VoiceInput

final class OpenAIAudioModelCatalogTests: XCTestCase {
    func testNormalizeWhisperModelFallsBackToWhitelistDefault() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.normalizeWhisperModel("legacy-model"),
            OpenAIAudioModelCatalog.whisperModels[0]
        )
    }

    func testNormalizeMultimodalEndpointFallsBackToWhitelistDefault() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.normalizeMultimodalEndpoint("https://example.com/v1/chat/completions"),
            OpenAIAudioModelCatalog.multimodalEndpoints[0]
        )
    }

    func testNormalizeWhisperEndpointAcceptsWhitelistedValueCaseInsensitively() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.normalizeWhisperEndpoint("HTTPS://API.OPENAI.COM/V1/AUDIO/TRANSCRIPTIONS"),
            OpenAIAudioModelCatalog.whisperEndpoints[0]
        )
    }
}
