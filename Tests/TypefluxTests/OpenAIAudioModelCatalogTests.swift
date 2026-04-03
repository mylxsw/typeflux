import XCTest

@testable import Typeflux

final class OpenAIAudioModelCatalogTests: XCTestCase {
    func testWhisperBuiltInOptionsMatchSupportedValues() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.whisperModels,
            ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
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
