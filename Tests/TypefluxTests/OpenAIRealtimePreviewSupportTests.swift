@testable import Typeflux
import XCTest

final class OpenAIRealtimePreviewSupportTests: XCTestCase {
    func testSupportUsesOpenAIDefaultWhenEndpointIsEmpty() {
        XCTAssertFalse(
            OpenAIRealtimePreviewSupport.isSupported(
                baseURL: "",
                model: "gpt-4o-transcribe",
            ),
        )
    }

    func testSupportRejectsWhisperOne() {
        XCTAssertFalse(
            OpenAIRealtimePreviewSupport.isSupported(
                baseURL: "https://api.openai.com/v1",
                model: "whisper-1",
            ),
        )
    }

    func testWebSocketURLUsesRealtimePathAndModelQuery() {
        let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini-transcribe",
        )

        XCTAssertEqual(
            url?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-4o-mini-transcribe",
        )
    }

    func testWebSocketURLNormalizesOpenAITranscriptionsEndpointToRealtime() {
        let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: "https://api.openai.com/v1/audio/transcriptions",
            model: "gpt-4o-transcribe",
        )

        XCTAssertEqual(
            url?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-4o-transcribe",
        )
    }

    func testWebSocketURLUsesDefaultEndpointWhenEmpty() {
        let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: "",
            model: "",
        )

        XCTAssertEqual(
            url?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-4o-transcribe",
        )
    }

    func testWebSocketURLUsesXAIWhisperFallbackForXAIEndpoint() {
        let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: "https://api.x.ai/v1/audio/transcriptions",
            model: " ",
        )

        XCTAssertEqual(
            url?.absoluteString,
            "wss://api.x.ai/v1/realtime?model=whisper-1",
        )
    }
}
