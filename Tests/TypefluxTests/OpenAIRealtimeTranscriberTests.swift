import XCTest
@testable import Typeflux

final class OpenAIRealtimeTranscriberTests: XCTestCase {

    // MARK: - isOpenAIEndpoint

    func testIsOpenAIEndpointWithStandardURL() {
        XCTAssertTrue(OpenAIRealtimeTranscriber.isOpenAIEndpoint("https://api.openai.com/v1"))
    }

    func testIsOpenAIEndpointWithTrailingSlash() {
        XCTAssertTrue(OpenAIRealtimeTranscriber.isOpenAIEndpoint("https://api.openai.com/v1/"))
    }

    func testIsOpenAIEndpointIsCaseInsensitive() {
        XCTAssertTrue(OpenAIRealtimeTranscriber.isOpenAIEndpoint("https://API.OPENAI.COM/v1"))
    }

    func testIsOpenAIEndpointWithCustomURL() {
        XCTAssertFalse(OpenAIRealtimeTranscriber.isOpenAIEndpoint("https://my-proxy.example.com/v1"))
    }

    func testIsOpenAIEndpointWithEmptyString() {
        XCTAssertFalse(OpenAIRealtimeTranscriber.isOpenAIEndpoint(""))
    }

    func testIsOpenAIEndpointWithWhitespace() {
        XCTAssertTrue(OpenAIRealtimeTranscriber.isOpenAIEndpoint("  https://api.openai.com/v1  "))
    }

    func testIsOpenAIEndpointWithInvalidURL() {
        XCTAssertFalse(OpenAIRealtimeTranscriber.isOpenAIEndpoint("not a url"))
    }

    func testIsOpenAIEndpointWithHTTP() {
        XCTAssertTrue(OpenAIRealtimeTranscriber.isOpenAIEndpoint("http://api.openai.com/v1"))
    }

    func testIsOpenAIEndpointWithSubdomain() {
        XCTAssertFalse(OpenAIRealtimeTranscriber.isOpenAIEndpoint("https://custom.api.openai.com/v1"))
    }

    // MARK: - shouldUseRealtime

    func testShouldUseRealtimeWithOpenAIAndSupportedModel() {
        XCTAssertTrue(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o-transcribe"
            )
        )
    }

    func testShouldUseRealtimeWithOpenAIAndMiniTranscribe() {
        XCTAssertTrue(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: "gpt-4o-mini-transcribe"
            )
        )
    }

    func testShouldUseRealtimeRejectsWhisperOne() {
        XCTAssertFalse(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: "whisper-1"
            )
        )
    }

    func testShouldUseRealtimeRejectsNonOpenAIURL() {
        XCTAssertFalse(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://my-proxy.example.com/v1",
                model: "gpt-4o-transcribe"
            )
        )
    }

    func testShouldUseRealtimeRejectsEmptyModel() {
        XCTAssertFalse(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: ""
            )
        )
    }

    func testShouldUseRealtimeRejectsEmptyBaseURL() {
        XCTAssertFalse(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "",
                model: "gpt-4o-transcribe"
            )
        )
    }

    func testShouldUseRealtimeWithWhitespaceInModel() {
        XCTAssertTrue(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: "  gpt-4o-transcribe  "
            )
        )
    }

    func testShouldUseRealtimeIsCaseInsensitiveForModel() {
        XCTAssertFalse(
            OpenAIRealtimeTranscriber.shouldUseRealtime(
                baseURL: "https://api.openai.com/v1",
                model: "Whisper-1"
            )
        )
    }
}
