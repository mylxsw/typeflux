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
