@testable import Typeflux
import XCTest

// MARK: - Mock LLM Services

private final class SpyLLMService: LLMService {
    var lastStreamRewriteRequest: LLMRewriteRequest?
    var completeCallCount = 0
    var completeJSONCallCount = 0

    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        lastStreamRewriteRequest = request
        return AsyncThrowingStream { $0.finish() }
    }

    func complete(systemPrompt _: String, userPrompt _: String) async throws -> String {
        completeCallCount += 1
        return "completed"
    }

    func completeJSON(systemPrompt _: String, userPrompt _: String, schema _: LLMJSONSchema) async throws -> String {
        completeJSONCallCount += 1
        return "{}"
    }
}

final class LLMRouterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var openAISpy: SpyLLMService!
    private var ollamaSpy: SpyLLMService!
    private var router: LLMRouter!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LLMRouterTests-\(UUID().uuidString)")!
        settings = SettingsStore(defaults: defaults)
        openAISpy = SpyLLMService()
        ollamaSpy = SpyLLMService()
        router = LLMRouter(settingsStore: settings, openAICompatible: openAISpy, ollama: ollamaSpy)
    }

    override func tearDown() {
        defaults = nil
        settings = nil
        openAISpy = nil
        ollamaSpy = nil
        router = nil
        super.tearDown()
    }

    func testCompleteRoutesToOpenAI() async throws {
        settings.llmProvider = .openAICompatible
        let result = try await router.complete(systemPrompt: "sys", userPrompt: "usr")
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(openAISpy.completeCallCount, 1)
        XCTAssertEqual(ollamaSpy.completeCallCount, 0)
    }

    func testCompleteRoutesToOllama() async throws {
        settings.llmProvider = .ollama
        let result = try await router.complete(systemPrompt: "sys", userPrompt: "usr")
        XCTAssertEqual(result, "completed")
        XCTAssertEqual(ollamaSpy.completeCallCount, 1)
        XCTAssertEqual(openAISpy.completeCallCount, 0)
    }

    func testCompleteJSONRoutesToOpenAI() async throws {
        settings.llmProvider = .openAICompatible
        let schema = LLMJSONSchema(name: "test", schema: [:])
        _ = try await router.completeJSON(systemPrompt: "sys", userPrompt: "usr", schema: schema)
        XCTAssertEqual(openAISpy.completeJSONCallCount, 1)
        XCTAssertEqual(ollamaSpy.completeJSONCallCount, 0)
    }

    func testStreamRewriteRoutesToCorrectProvider() {
        settings.llmProvider = .openAICompatible
        let request = LLMRewriteRequest(mode: .rewriteTranscript, sourceText: "test", spokenInstruction: nil, personaPrompt: nil)
        _ = router.streamRewrite(request: request)
        XCTAssertNotNil(openAISpy.lastStreamRewriteRequest)
        XCTAssertNil(ollamaSpy.lastStreamRewriteRequest)
    }
}
