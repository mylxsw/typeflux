@testable import Typeflux
import XCTest

// MARK: - Mock Types

private final class MockLLMAgentService: LLMAgentService {
    var lastRequest: LLMAgentRequest?
    var resultToReturn: Any?
    var errorToThrow: Error?

    func runTool<T: Decodable & Sendable>(request: LLMAgentRequest, decoding _: T.Type) async throws -> T {
        lastRequest = request
        if let error = errorToThrow {
            throw error
        }
        guard let result = resultToReturn as? T else {
            throw LLMAgentError.invalidToolArguments
        }
        return result
    }
}

final class LLMAgentRouterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var remoteSpy: MockLLMAgentService!
    private var ollamaSpy: MockLLMAgentService!
    private var router: LLMAgentRouter!

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LLMAgentRouterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = SettingsStore(defaults: defaults)
        remoteSpy = MockLLMAgentService()
        ollamaSpy = MockLLMAgentService()
        router = LLMAgentRouter(settingsStore: settings, remote: remoteSpy, ollama: ollamaSpy)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        remoteSpy = nil
        ollamaSpy = nil
        router = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoutesToRemoteWhenOpenAICompatible() async throws {
        settings.llmProvider = .openAICompatible
        remoteSpy.resultToReturn = "remote result"

        let request = LLMAgentRequest(systemPrompt: "sys", userPrompt: "usr", tools: [])
        let result: String = try await router.runTool(request: request, decoding: String.self)

        XCTAssertEqual(result, "remote result")
        XCTAssertNotNil(remoteSpy.lastRequest)
        XCTAssertNil(ollamaSpy.lastRequest)
    }

    func testRoutesToOllamaWhenOllamaProvider() async throws {
        settings.llmProvider = .ollama
        ollamaSpy.resultToReturn = "ollama result"

        let request = LLMAgentRequest(systemPrompt: "sys", userPrompt: "usr", tools: [])
        let result: String = try await router.runTool(request: request, decoding: String.self)

        XCTAssertEqual(result, "ollama result")
        XCTAssertNotNil(ollamaSpy.lastRequest)
        XCTAssertNil(remoteSpy.lastRequest)
    }

    func testOllamaAgentServiceThrowsUnsupportedProvider() async {
        let service = OllamaAgentService()
        let request = LLMAgentRequest(systemPrompt: "sys", userPrompt: "usr", tools: [])

        do {
            let _: String = try await service.runTool(request: request, decoding: String.self)
            XCTFail("Should throw unsupportedProvider")
        } catch let error as LLMAgentError {
            XCTAssertEqual(error, .unsupportedProvider)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
