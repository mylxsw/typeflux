@testable import Typeflux
import XCTest

final class OpenAIEndpointResolverTests: XCTestCase {
    func testResolveKeepsFullTranscriptionEndpoint() throws {
        let configuredURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/audio/transcriptions"))

        let resolvedURL = OpenAIEndpointResolver.resolve(from: configuredURL, path: "audio/transcriptions")

        XCTAssertEqual(resolvedURL.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testResolveAppendsTranscriptionPathForLegacyBaseURL() throws {
        let configuredURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1"))

        let resolvedURL = OpenAIEndpointResolver.resolve(from: configuredURL, path: "audio/transcriptions")

        XCTAssertEqual(resolvedURL.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
    }

    func testResolveKeepsFullChatCompletionsEndpoint() throws {
        let configuredURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/chat/completions"))

        let resolvedURL = OpenAIEndpointResolver.resolve(from: configuredURL, path: "chat/completions")

        XCTAssertEqual(resolvedURL.absoluteString, "https://api.openai.com/v1/chat/completions")
    }
}

// MARK: - Extended OpenAIEndpointResolver tests

extension OpenAIEndpointResolverTests {
    func testResolveAppendsChatCompletionsToBaseURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1"))
        let resolved = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        XCTAssertEqual(resolved.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testResolveKeepsMessagesEndpointForAnthropic() throws {
        let fullURL = try XCTUnwrap(URL(string: "https://api.anthropic.com/v1/messages"))
        let resolved = OpenAIEndpointResolver.resolve(from: fullURL, path: "messages")
        XCTAssertEqual(resolved.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testResolveAppendsMessagesPathForAnthropicBase() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://api.anthropic.com/v1"))
        let resolved = OpenAIEndpointResolver.resolve(from: baseURL, path: "messages")
        XCTAssertEqual(resolved.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testResolveHandlesTrailingSlashInConfiguredURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/"))
        let resolved = OpenAIEndpointResolver.resolve(from: baseURL, path: "chat/completions")
        // Should not double-append
        XCTAssertTrue(resolved.absoluteString.contains("chat/completions"))
        XCTAssertFalse(resolved.absoluteString.contains("chat/completions/chat/completions"))
    }

    func testResolveHandlesLeadingSlashInPath() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://api.example.com/v1"))
        let resolved = OpenAIEndpointResolver.resolve(from: baseURL, path: "/chat/completions")
        XCTAssertTrue(resolved.absoluteString.contains("chat/completions"))
    }

    func testResolveCaseInsensitiveMatch() throws {
        // URL with uppercase path component should still match
        let fullURL = try XCTUnwrap(URL(string: "https://api.openai.com/v1/Chat/Completions"))
        let resolved = OpenAIEndpointResolver.resolve(from: fullURL, path: "chat/completions")
        XCTAssertEqual(resolved.absoluteString, "https://api.openai.com/v1/Chat/Completions")
    }

    func testResolveCustomPath() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://custom.api.com/api"))
        let resolved = OpenAIEndpointResolver.resolve(from: baseURL, path: "v1/audio/speech")
        XCTAssertTrue(resolved.absoluteString.contains("v1/audio/speech"))
    }
}
