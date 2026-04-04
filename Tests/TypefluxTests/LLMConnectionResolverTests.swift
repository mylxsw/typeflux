import XCTest
@testable import Typeflux

final class LLMConnectionResolverTests: XCTestCase {

    // MARK: - Non-free provider resolution

    func testResolveWithValidBaseURLReturnsConnection() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-4",
            apiKey: "sk-test"
        )

        XCTAssertEqual(connection.provider, .openAI)
        XCTAssertEqual(connection.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(connection.model, "gpt-4")
        XCTAssertEqual(connection.apiKey, "sk-test")
        XCTAssertTrue(connection.additionalHeaders.isEmpty)
    }

    func testResolveWithEmptyModelUsesProviderDefault() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            model: "",
            apiKey: "sk-test"
        )

        XCTAssertEqual(connection.model, LLMRemoteProvider.openAI.defaultModel)
    }

    func testResolveWithWhitespaceOnlyModelUsesProviderDefault() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .deepSeek,
            baseURL: "https://api.deepseek.com",
            model: "   ",
            apiKey: "sk-test"
        )

        XCTAssertEqual(connection.model, LLMRemoteProvider.deepSeek.defaultModel)
    }

    func testResolveTrimsModelWhitespace() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "https://api.example.com",
            model: "  gpt-4  ",
            apiKey: "key"
        )

        XCTAssertEqual(connection.model, "gpt-4")
    }

    // MARK: - Invalid base URL

    func testResolveThrowsForEmptyBaseURL() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "",
            model: "gpt-4",
            apiKey: "sk-test"
        ))
    }

    func testResolveThrowsForInvalidBaseURL() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .openAI,
            baseURL: "not a url",
            model: "gpt-4",
            apiKey: "sk-test"
        ))
    }

    // MARK: - Free model provider

    func testFreeModelThrowsForEmptyModel() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .freeModel,
            baseURL: "",
            model: "",
            apiKey: ""
        ))
    }

    func testFreeModelThrowsForUnknownModel() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .freeModel,
            baseURL: "",
            model: "nonexistent-model-xyz",
            apiKey: ""
        ))
    }

    func testFreeModelResolvesRegisteredModel() throws {
        let modelNames = FreeLLMModelRegistry.suggestedModelNames
        guard let firstName = modelNames.first else { return }

        let connection = try LLMConnectionResolver.resolve(
            provider: .freeModel,
            baseURL: "",
            model: firstName,
            apiKey: ""
        )

        XCTAssertEqual(connection.provider, .freeModel)
        XCTAssertFalse(connection.baseURL.absoluteString.isEmpty)
        XCTAssertFalse(connection.model.isEmpty)
    }
}

// MARK: - Extended LLMConnectionResolver tests

extension LLMConnectionResolverTests {

    // MARK: - URL trimming

    func testResolveTrimsWhitespaceFromBaseURL() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "  https://api.example.com/v1  ",
            model: "model-x",
            apiKey: "sk-123"
        )
        XCTAssertEqual(connection.baseURL.absoluteString, "https://api.example.com/v1")
    }

    func testResolveTrimsWhitespaceFromModel() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            model: "  gpt-4o  ",
            apiKey: "sk-123"
        )
        XCTAssertEqual(connection.model, "gpt-4o")
    }

    // MARK: - Default model fallback

    func testResolveUsesProviderDefaultModelWhenModelIsEmpty() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .openAI,
            baseURL: "https://api.openai.com/v1",
            model: "",
            apiKey: "sk-123"
        )
        XCTAssertEqual(connection.model, LLMRemoteProvider.openAI.defaultModel)
    }

    func testResolveUsesProviderDefaultModelWhenModelIsWhitespace() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            model: "  ",
            apiKey: "sk-123"
        )
        XCTAssertEqual(connection.model, LLMRemoteProvider.anthropic.defaultModel)
    }

    // MARK: - Non-HTTP scheme rejection

    func testResolveThrowsForFTPScheme() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "ftp://api.example.com/v1",
            model: "m",
            apiKey: ""
        ))
    }

    func testResolveThrowsForFileScheme() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "file:///some/path",
            model: "m",
            apiKey: ""
        ))
    }

    // MARK: - ResolvedLLMConnection properties

    func testResolvedConnectionHasCorrectProvider() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            model: "openai/gpt-4o",
            apiKey: "sk-or-key"
        )
        XCTAssertEqual(connection.provider, .openRouter)
        XCTAssertEqual(connection.apiKey, "sk-or-key")
    }

    func testResolvedConnectionPreservesAPIKey() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com/v1",
            model: "claude-3",
            apiKey: "sk-ant-xyz"
        )
        XCTAssertEqual(connection.apiKey, "sk-ant-xyz")
    }

    func testResolvedConnectionHTTPSchemeIsAllowed() throws {
        let connection = try LLMConnectionResolver.resolve(
            provider: .custom,
            baseURL: "http://localhost:11434/v1",
            model: "llama3",
            apiKey: ""
        )
        XCTAssertEqual(connection.baseURL.scheme, "http")
        XCTAssertEqual(connection.model, "llama3")
    }

    // MARK: - Free model whitespace handling

    func testFreeModelThrowsForWhitespaceOnlyModel() {
        XCTAssertThrowsError(try LLMConnectionResolver.resolve(
            provider: .freeModel,
            baseURL: "",
            model: "  ",
            apiKey: ""
        ))
    }
}
