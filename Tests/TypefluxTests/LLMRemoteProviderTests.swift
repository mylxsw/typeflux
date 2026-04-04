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
            [
                "grok-4-1-fast-reasoning",
                "grok-4-1-fast-non-reasoning",
                "grok-4.20-0309-reasoning",
                "grok-4.20-0309-non-reasoning",
            ]
        )

        XCTAssertEqual(LLMRemoteProvider.xiaomi.apiStyle, .openAICompatible)
        XCTAssertEqual(LLMRemoteProvider.xiaomi.defaultBaseURL, "https://api.xiaomimimo.com/v1")
        XCTAssertEqual(
            LLMRemoteProvider.xiaomi.suggestedModels,
            ["mimo-v2-pro", "mimo-v2-flash", "mimo-v2-omni"]
        )
    }

    func testTextLLMConfigurationFallsBackToMultimodalSTTSettingsWhenRemoteLLMIsIncomplete() {
        let store = SettingsStore()
        store.sttProvider = .multimodalLLM
        store.multimodalLLMBaseURL = "https://api.example.com/v1"
        store.multimodalLLMModel = "gpt-4o-audio-preview"
        store.multimodalLLMAPIKey = "sk-multimodal"
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.setLLMBaseURL("", for: .custom)
        store.setLLMModel("", for: .custom)
        store.setLLMAPIKey("", for: .custom)

        let config = store.textLLMConfiguration()

        XCTAssertEqual(config.provider, .custom)
        XCTAssertEqual(config.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(config.model, "gpt-4o-audio-preview")
        XCTAssertEqual(config.apiKey, "sk-multimodal")
    }

    func testTextLLMConfigurationKeepsDedicatedRemoteLLMSettingsWhenComplete() {
        let store = SettingsStore()
        store.sttProvider = .multimodalLLM
        store.multimodalLLMBaseURL = "https://api.example.com/v1"
        store.multimodalLLMModel = "gpt-4o-audio-preview"
        store.multimodalLLMAPIKey = "sk-multimodal"
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.setLLMBaseURL("https://llm.example.com/v1", for: .custom)
        store.setLLMModel("text-model", for: .custom)
        store.setLLMAPIKey("", for: .custom)

        let config = store.textLLMConfiguration()

        XCTAssertEqual(config.provider, .custom)
        XCTAssertEqual(config.baseURL, "https://llm.example.com/v1")
        XCTAssertEqual(config.model, "text-model")
        XCTAssertEqual(config.apiKey, "")
    }

    private func clearLLMKeys() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("llm.") {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - LLMRemoteProvider extended property tests

extension LLMRemoteProviderTests {

    func testAllProviderCasesHaveDisplayNames() {
        for provider in LLMRemoteProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty, "\(provider) should have a display name")
        }
    }

    func testAllProviderCasesHaveAPIStyles() {
        let validStyles: Set<LLMRemoteAPIStyle> = [.openAICompatible, .anthropic, .gemini]
        for provider in LLMRemoteProvider.allCases {
            XCTAssertTrue(validStyles.contains(provider.apiStyle), "\(provider) should have a valid API style")
        }
    }

    func testAnthropicUsesAnthropicAPIStyle() {
        XCTAssertEqual(LLMRemoteProvider.anthropic.apiStyle, .anthropic)
    }

    func testGeminiUsesGeminiAPIStyle() {
        XCTAssertEqual(LLMRemoteProvider.gemini.apiStyle, .gemini)
    }

    func testOpenAIUsesOpenAICompatibleAPIStyle() {
        XCTAssertEqual(LLMRemoteProvider.openAI.apiStyle, .openAICompatible)
    }

    func testDeepSeekUsesOpenAICompatibleAPIStyle() {
        XCTAssertEqual(LLMRemoteProvider.deepSeek.apiStyle, .openAICompatible)
    }

    func testCustomUsesOpenAICompatibleAPIStyle() {
        XCTAssertEqual(LLMRemoteProvider.custom.apiStyle, .openAICompatible)
    }

    func testOpenAIDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.openAI.defaultBaseURL, "https://api.openai.com/v1")
    }

    func testAnthropicDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.anthropic.defaultBaseURL, "https://api.anthropic.com/v1")
    }

    func testGeminiDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.gemini.defaultBaseURL, "https://generativelanguage.googleapis.com/v1beta")
    }

    func testDeepSeekDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.deepSeek.defaultBaseURL, "https://api.deepseek.com/v1")
    }

    func testKimiDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.kimi.defaultBaseURL, "https://api.moonshot.cn/v1")
    }

    func testQwenDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.qwen.defaultBaseURL, "https://dashscope.aliyuncs.com/compatible-mode/v1")
    }

    func testOpenRouterDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.openRouter.defaultBaseURL, "https://openrouter.ai/api/v1")
    }

    func testOpenAISuggestedModelsNotEmpty() {
        XCTAssertFalse(LLMRemoteProvider.openAI.suggestedModels.isEmpty)
    }

    func testAnthropicSuggestedModelsNotEmpty() {
        XCTAssertFalse(LLMRemoteProvider.anthropic.suggestedModels.isEmpty)
    }

    func testGeminiSuggestedModelsNotEmpty() {
        XCTAssertFalse(LLMRemoteProvider.gemini.suggestedModels.isEmpty)
    }

    func testDeepSeekSuggestedModelsContainsDeepseekChat() {
        XCTAssertTrue(LLMRemoteProvider.deepSeek.suggestedModels.contains("deepseek-chat"))
    }

    func testOpenAISupportsNativeStructuredOutput() {
        XCTAssertTrue(LLMRemoteProvider.openAI.supportsNativeStructuredOutput)
    }

    func testGeminiSupportsNativeStructuredOutput() {
        XCTAssertTrue(LLMRemoteProvider.gemini.supportsNativeStructuredOutput)
    }

    func testAnthropicDoesNotSupportNativeStructuredOutput() {
        XCTAssertFalse(LLMRemoteProvider.anthropic.supportsNativeStructuredOutput)
    }

    func testFreeModelDoesNotSupportNativeStructuredOutput() {
        XCTAssertFalse(LLMRemoteProvider.freeModel.supportsNativeStructuredOutput)
    }

    func testCustomProviderHasEmptyDefaultBaseURL() {
        XCTAssertEqual(LLMRemoteProvider.custom.defaultBaseURL, "")
    }

    func testCustomProviderHasEmptyDefaultModel() {
        XCTAssertEqual(LLMRemoteProvider.custom.defaultModel, "")
    }

    func testFreeModelDefaultModel() {
        XCTAssertEqual(LLMRemoteProvider.freeModel.defaultModel, "")
    }

    func testEndpointPresetsForProviderWithNoPresets() {
        // Custom provider has no endpoint presets
        XCTAssertTrue(LLMRemoteProvider.custom.endpointPresets.isEmpty)
    }

    func testEndpointPresetsForOpenAI() {
        // OpenAI has at least one preset
        XCTAssertFalse(LLMRemoteProvider.openAI.endpointPresets.isEmpty)
    }

    func testProviderRawValueRoundTrip() {
        for provider in LLMRemoteProvider.allCases {
            let raw = provider.rawValue
            let recovered = LLMRemoteProvider(rawValue: raw)
            XCTAssertEqual(recovered, provider, "\(provider) raw value round trip failed")
        }
    }

    func testStudioProviderIDMappingIsComplete() {
        for provider in LLMRemoteProvider.allCases {
            let studioID = provider.studioProviderID
            let recovered = LLMRemoteProvider.from(providerID: studioID)
            XCTAssertEqual(recovered, provider, "\(provider) studio ID round trip failed")
        }
    }

    func testLLMRemoteAPIStyleIsEquatable() {
        XCTAssertEqual(LLMRemoteAPIStyle.openAICompatible, LLMRemoteAPIStyle.openAICompatible)
        XCTAssertNotEqual(LLMRemoteAPIStyle.anthropic, LLMRemoteAPIStyle.gemini)
    }

    func testLLMRemoteEndpointPresetHasLabelKeyAndURL() throws {
        let preset = try XCTUnwrap(LLMRemoteProvider.zhipu.endpointPresets.first)
        XCTAssertFalse(preset.url.isEmpty)
        XCTAssertFalse(preset.labelKey.isEmpty)
    }
}
