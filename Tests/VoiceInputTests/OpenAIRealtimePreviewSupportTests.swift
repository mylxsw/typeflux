import XCTest
@testable import VoiceInput

final class OpenAIRealtimePreviewSupportTests: XCTestCase {
    func testSupportRejectsWhisperOne() {
        XCTAssertFalse(
            OpenAIRealtimePreviewSupport.isSupported(
                baseURL: "https://api.openai.com/v1",
                model: "whisper-1"
            )
        )
    }

    func testWebSocketURLUsesRealtimePathAndModelQuery() {
        let url = OpenAIRealtimePreviewSupport.webSocketURL(
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini-transcribe"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "wss://api.openai.com/v1/realtime?model=gpt-4o-mini-transcribe"
        )
    }
}
