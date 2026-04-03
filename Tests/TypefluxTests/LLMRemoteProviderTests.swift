import XCTest
@testable import Typeflux

final class LLMRemoteProviderTests: XCTestCase {
    private let defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        clearLLMKeys()
    }

    override func tearDown() {
        clearLLMKeys()
        super.tearDown()
    }

    func testCustomProviderFallsBackToLegacyValues() {
        defaults.set(LLMRemoteProvider.custom.rawValue, forKey: "llm.remote.provider")
        defaults.set("https://example.com/v1", forKey: "llm.baseURL")
        defaults.set("custom-model", forKey: "llm.model")
        defaults.set("sk-custom", forKey: "llm.apiKey")

        let store = SettingsStore()

        XCTAssertEqual(store.llmBaseURL(for: .custom), "https://example.com/v1")
        XCTAssertEqual(store.llmModel(for: .custom), "custom-model")
        XCTAssertEqual(store.llmAPIKey(for: .custom), "sk-custom")
    }

    func testProvidersKeepIndependentEndpointModelAndAPIKey() {
        let store = SettingsStore()

        store.setLLMBaseURL("https://openrouter.ai/api/v1", for: .openRouter)
        store.setLLMModel("openrouter/auto", for: .openRouter)
        store.setLLMAPIKey("sk-openrouter", for: .openRouter)
        store.setLLMBaseURL("https://api.openai.com/v1", for: .openAI)
        store.setLLMModel("gpt-4o", for: .openAI)
        store.setLLMAPIKey("sk-openai", for: .openAI)
        store.setLLMBaseURL("https://example.com/deepseek/v1", for: .deepSeek)
        store.setLLMModel("deepseek-chat", for: .deepSeek)
        store.setLLMAPIKey("sk-deepseek", for: .deepSeek)

        XCTAssertEqual(store.llmBaseURL(for: .openRouter), "https://openrouter.ai/api/v1")
        XCTAssertEqual(store.llmModel(for: .openRouter), "openrouter/auto")
        XCTAssertEqual(store.llmAPIKey(for: .openRouter), "sk-openrouter")
        XCTAssertEqual(store.llmBaseURL(for: .openAI), "https://api.openai.com/v1")
        XCTAssertEqual(store.llmBaseURL(for: .deepSeek), "https://example.com/deepseek/v1")
        XCTAssertEqual(store.llmModel(for: .openAI), "gpt-4o")
        XCTAssertEqual(store.llmModel(for: .deepSeek), "deepseek-chat")
        XCTAssertEqual(store.llmAPIKey(for: .openAI), "sk-openai")
        XCTAssertEqual(store.llmAPIKey(for: .deepSeek), "sk-deepseek")
    }

    func testProviderIDRoundTrip() {
        for provider in LLMRemoteProvider.allCases {
            XCTAssertEqual(LLMRemoteProvider.from(providerID: provider.studioProviderID), provider)
        }
    }

    func testStructuredOutputSupportIsOptInPerProvider() {
        XCTAssertTrue(LLMRemoteProvider.openAI.supportsNativeStructuredOutput)
        XCTAssertTrue(LLMRemoteProvider.gemini.supportsNativeStructuredOutput)
        XCTAssertFalse(LLMRemoteProvider.freeModel.supportsNativeStructuredOutput)
        XCTAssertFalse(LLMRemoteProvider.custom.supportsNativeStructuredOutput)
        XCTAssertFalse(LLMRemoteProvider.openRouter.supportsNativeStructuredOutput)
        XCTAssertFalse(LLMRemoteProvider.deepSeek.supportsNativeStructuredOutput)
    }

    func testFreeModelProviderUsesRegistryDrivenDefaults() {
        XCTAssertEqual(LLMRemoteProvider.freeModel.defaultBaseURL, "")
        XCTAssertEqual(LLMRemoteProvider.freeModel.defaultModel, "")
        XCTAssertEqual(LLMRemoteProvider.freeModel.apiStyle, .openAICompatible)
    }

    func testProvidersWithRegionalEndpointsExposeOfficialPresets() {
        XCTAssertEqual(
            LLMRemoteProvider.zhipu.endpointPresets.map(\.url),
            [
                "https://api.z.ai/api/paas/v4",
                "https://open.bigmodel.cn/api/paas/v4",
            ]
        )
        XCTAssertEqual(
            LLMRemoteProvider.minimax.endpointPresets.map(\.url),
            [
                "https://api.minimax.io/v1",
                "https://api.minimaxi.com/v1",
            ]
        )
    }

    func testGrokAndXiaomiProvidersExposeOpenAICompatibleDefaults() {
        XCTAssertEqual(LLMRemoteProvider.grok.apiStyle, .openAICompatible)
        XCTAssertEqual(LLMRemoteProvider.grok.defaultBaseURL, "https://api.x.ai/v1")
        XCTAssertEqual(
            LLMRemoteProvider.grok.suggestedModels,
            ["grok-4-1-fast-reasoning", "grok-4", "grok-3", "grok-3-mini"]
        )

        XCTAssertEqual(LLMRemoteProvider.xiaomi.apiStyle, .openAICompatible)
        XCTAssertEqual(LLMRemoteProvider.xiaomi.defaultBaseURL, "https://api.xiaomimimo.com/v1")
        XCTAssertEqual(
            LLMRemoteProvider.xiaomi.suggestedModels,
            ["mimo-v2-pro", "mimo-v2-flash", "mimo-v2-omni"]
        )
    }

    private func clearLLMKeys() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("llm.") {
            defaults.removeObject(forKey: key)
        }
    }
}
