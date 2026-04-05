@testable import Typeflux
import XCTest

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - STT Provider

    func testDefaultSTTProvider() {
        XCTAssertEqual(store.sttProvider, .whisperAPI)
    }

    func testSetAndGetSTTProvider() {
        store.sttProvider = .localModel
        XCTAssertEqual(store.sttProvider, .localModel)
    }

    func testInvalidSTTProviderFallsBackToDefault() {
        defaults.set("nonexistent", forKey: "stt.provider")
        XCTAssertEqual(store.sttProvider, .whisperAPI)
    }

    // MARK: - LLM Provider

    func testDefaultLLMProvider() {
        XCTAssertEqual(store.llmProvider, .openAICompatible)
    }

    func testSetAndGetLLMProvider() {
        store.llmProvider = .ollama
        XCTAssertEqual(store.llmProvider, .ollama)
    }

    // MARK: - Appearance Mode

    func testDefaultAppearanceMode() {
        XCTAssertEqual(store.appearanceMode, .light)
    }

    func testSetAppearanceMode() {
        store.appearanceMode = .dark
        XCTAssertEqual(store.appearanceMode, .dark)
    }

    func testAppearanceModeChangePostsNotification() {
        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            expectation.fulfill()
        }

        store.appearanceMode = .dark
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testAppearanceModeNoNotificationWhenSameValue() {
        store.appearanceMode = .dark

        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .appearanceModeDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            notificationFired = true
        }

        store.appearanceMode = .dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(notificationFired)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Sound Effects

    func testDefaultSoundEffectsEnabled() {
        XCTAssertTrue(store.soundEffectsEnabled)
    }

    func testSetSoundEffectsDisabled() {
        store.soundEffectsEnabled = false
        XCTAssertFalse(store.soundEffectsEnabled)
    }

    // MARK: - Mute System Output

    func testDefaultMuteSystemOutput() {
        XCTAssertFalse(store.muteSystemOutputDuringRecording)
    }

    func testSetMuteSystemOutput() {
        store.muteSystemOutputDuringRecording = true
        XCTAssertTrue(store.muteSystemOutputDuringRecording)
    }

    // MARK: - HistoryRetentionPolicy

    func testRetentionPolicyDays() {
        XCTAssertEqual(HistoryRetentionPolicy.never.days, 0)
        XCTAssertEqual(HistoryRetentionPolicy.oneDay.days, 1)
        XCTAssertEqual(HistoryRetentionPolicy.oneWeek.days, 7)
        XCTAssertEqual(HistoryRetentionPolicy.oneMonth.days, 30)
        XCTAssertNil(HistoryRetentionPolicy.forever.days)
    }

    func testRetentionPolicyTitlesAreNonEmpty() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertFalse(policy.title.isEmpty, "\(policy) title should not be empty")
        }
    }

    func testRetentionPolicyDetailsAreNonEmpty() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertFalse(policy.detail.isEmpty, "\(policy) detail should not be empty")
        }
    }

    func testRetentionPolicyId() {
        for policy in HistoryRetentionPolicy.allCases {
            XCTAssertEqual(policy.id, policy.rawValue)
        }
    }

    // MARK: - LLM Remote Provider

    func testDefaultLLMRemoteProvider() {
        XCTAssertEqual(store.llmRemoteProvider, .custom)
    }

    func testSetAndGetLLMRemoteProvider() {
        store.llmRemoteProvider = .openAI
        XCTAssertEqual(store.llmRemoteProvider, .openAI)
    }

    // MARK: - Preferred Microphone ID

    func testDefaultPreferredMicrophoneID() {
        XCTAssertEqual(store.preferredMicrophoneID, AudioDeviceManager.automaticDeviceID)
    }

    func testSetAndGetPreferredMicrophoneID() {
        store.preferredMicrophoneID = "BuiltInMic-1234"
        XCTAssertEqual(store.preferredMicrophoneID, "BuiltInMic-1234")
    }

    // MARK: - History Retention Policy Store

    func testDefaultHistoryRetentionPolicy() {
        XCTAssertEqual(store.historyRetentionPolicy, .oneWeek)
    }

    func testSetAndGetHistoryRetentionPolicy() {
        store.historyRetentionPolicy = .oneMonth
        XCTAssertEqual(store.historyRetentionPolicy, .oneMonth)
    }

    // MARK: - Ollama Settings

    func testDefaultOllamaBaseURL() {
        XCTAssertEqual(store.ollamaBaseURL, "http://127.0.0.1:11434")
    }

    func testSetAndGetOllamaBaseURL() {
        store.ollamaBaseURL = "http://localhost:9999"
        XCTAssertEqual(store.ollamaBaseURL, "http://localhost:9999")
    }

    func testDefaultOllamaModel() {
        XCTAssertEqual(store.ollamaModel, "qwen3.5:7b")
    }

    func testSetAndGetOllamaModel() {
        store.ollamaModel = "llama3:8b"
        XCTAssertEqual(store.ollamaModel, "llama3:8b")
    }

    func testDefaultOllamaAutoSetup() {
        XCTAssertTrue(store.ollamaAutoSetup)
    }

    func testSetOllamaAutoSetupDisabled() {
        store.ollamaAutoSetup = false
        XCTAssertFalse(store.ollamaAutoSetup)
    }

    // MARK: - Whisper Settings

    func testDefaultWhisperBaseURL() {
        XCTAssertEqual(store.whisperBaseURL, "")
    }

    func testSetAndGetWhisperBaseURL() {
        store.whisperBaseURL = "https://whisper.example.com/v1"
        XCTAssertEqual(store.whisperBaseURL, "https://whisper.example.com/v1")
    }

    func testDefaultWhisperModel() {
        XCTAssertEqual(store.whisperModel, "")
    }

    func testSetAndGetWhisperModel() {
        store.whisperModel = "whisper-1"
        XCTAssertEqual(store.whisperModel, "whisper-1")
    }

    func testDefaultWhisperAPIKey() {
        XCTAssertEqual(store.whisperAPIKey, "")
    }

    func testResolvedDefaultWhisperConfigurationUsesOpenAIDefaults() {
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperEndpoint(store.whisperBaseURL),
            "https://api.openai.com/v1/audio/transcriptions",
        )
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(store.whisperModel),
            "gpt-4o-transcribe",
        )
    }

    func testResolvedDefaultWhisperConfigurationUsesXAIWhisperFallbackForXAIEndpoint() {
        store.whisperBaseURL = "https://api.x.ai/v1/audio/transcriptions"

        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(
                store.whisperModel,
                endpoint: store.whisperBaseURL,
            ),
            "whisper-1",
        )
    }

    func testSetAndGetWhisperAPIKey() {
        store.whisperAPIKey = "sk-test-key"
        XCTAssertEqual(store.whisperAPIKey, "sk-test-key")
    }

    // MARK: - Free STT Model

    func testDefaultFreeSTTModel() {
        let expected = FreeSTTModelRegistry.suggestedModelNames.first ?? ""
        XCTAssertEqual(store.freeSTTModel, expected)
    }

    func testSetAndGetFreeSTTModel() {
        store.freeSTTModel = "custom-free-model"
        XCTAssertEqual(store.freeSTTModel, "custom-free-model")
    }

    // MARK: - Local STT Model

    func testDefaultLocalSTTModel() {
        XCTAssertEqual(store.localSTTModel, .whisperLocal)
    }

    func testSetAndGetLocalSTTModel() {
        store.localSTTModel = .senseVoiceSmall
        XCTAssertEqual(store.localSTTModel, .senseVoiceSmall)
    }

    // MARK: - Multimodal LLM Settings

    func testDefaultMultimodalLLMBaseURL() {
        XCTAssertEqual(store.multimodalLLMBaseURL, "")
    }

    func testSetAndGetMultimodalLLMBaseURL() {
        store.multimodalLLMBaseURL = "https://multimodal.example.com"
        XCTAssertEqual(store.multimodalLLMBaseURL, "https://multimodal.example.com")
    }

    func testDefaultMultimodalLLMModel() {
        XCTAssertEqual(store.multimodalLLMModel, "")
    }

    func testSetAndGetMultimodalLLMModel() {
        store.multimodalLLMModel = "gpt-4o-audio-preview"
        XCTAssertEqual(store.multimodalLLMModel, "gpt-4o-audio-preview")
    }

    func testDefaultMultimodalLLMAPIKey() {
        XCTAssertEqual(store.multimodalLLMAPIKey, "")
    }

    func testSetAndGetMultimodalLLMAPIKey() {
        store.multimodalLLMAPIKey = "sk-multimodal"
        XCTAssertEqual(store.multimodalLLMAPIKey, "sk-multimodal")
    }

    // MARK: - AliCloud

    func testDefaultAliCloudAPIKey() {
        XCTAssertEqual(store.aliCloudAPIKey, "")
    }

    func testSetAndGetAliCloudAPIKey() {
        store.aliCloudAPIKey = "ali-key-123"
        XCTAssertEqual(store.aliCloudAPIKey, "ali-key-123")
    }

    // MARK: - Doubao

    func testDefaultDoubaoAppID() {
        XCTAssertEqual(store.doubaoAppID, "")
    }

    func testSetAndGetDoubaoAppID() {
        store.doubaoAppID = "doubao-app-1"
        XCTAssertEqual(store.doubaoAppID, "doubao-app-1")
    }

    func testDefaultDoubaoAccessToken() {
        XCTAssertEqual(store.doubaoAccessToken, "")
    }

    func testSetAndGetDoubaoAccessToken() {
        store.doubaoAccessToken = "token-abc"
        XCTAssertEqual(store.doubaoAccessToken, "token-abc")
    }

    func testDefaultDoubaoResourceIDMigration() {
        XCTAssertEqual(store.doubaoResourceID, "volc.seedasr.sauc.duration")
    }

    func testDoubaoResourceIDMigratesLegacyValue() {
        defaults.set("volc.bigasr.sauc.duration", forKey: "stt.doubao.resourceID")
        XCTAssertEqual(store.doubaoResourceID, "volc.seedasr.sauc.duration")
    }

    func testDoubaoResourceIDPreservesCustomValue() {
        store.doubaoResourceID = "custom.resource.id"
        XCTAssertEqual(store.doubaoResourceID, "custom.resource.id")
    }

    // MARK: - Persona Settings

    func testDefaultPersonaRewriteEnabled() {
        XCTAssertFalse(store.personaRewriteEnabled)
    }

    func testSetPersonaRewriteEnabled() {
        store.personaRewriteEnabled = true
        XCTAssertTrue(store.personaRewriteEnabled)
    }

    func testDefaultPersonaHotkeyAppliesToSelection() {
        XCTAssertTrue(store.personaHotkeyAppliesToSelection)
    }

    func testSetPersonaHotkeyAppliesToSelection() {
        store.personaHotkeyAppliesToSelection = false
        XCTAssertFalse(store.personaHotkeyAppliesToSelection)
    }

    func testDefaultActivePersonaID() {
        XCTAssertEqual(store.activePersonaID, "")
    }

    func testSetAndGetActivePersonaID() {
        let id = UUID().uuidString
        store.activePersonaID = id
        XCTAssertEqual(store.activePersonaID, id)
    }

    // MARK: - Misc Boolean Settings

    func testDefaultUseAppleSpeechFallback() {
        XCTAssertFalse(store.useAppleSpeechFallback)
    }

    func testSetUseAppleSpeechFallback() {
        store.useAppleSpeechFallback = true
        XCTAssertTrue(store.useAppleSpeechFallback)
    }

    func testDefaultAutomaticVocabularyCollectionEnabled() {
        XCTAssertTrue(store.automaticVocabularyCollectionEnabled)
    }

    func testSetAutomaticVocabularyCollectionDisabled() {
        store.automaticVocabularyCollectionEnabled = false
        XCTAssertFalse(store.automaticVocabularyCollectionEnabled)
    }

    // MARK: - Personas Computed Property

    func testDefaultPersonasIncludesSystemPersonas() {
        let personas = store.personas
        let systemPersonas = personas.filter(\.isSystem)
        XCTAssertEqual(systemPersonas.count, 2)
        XCTAssertTrue(personas.contains(where: { $0.name == "Typeflux" }))
        XCTAssertTrue(personas.contains(where: { $0.name == "English Translator" }))
    }

    func testPersonasEncodeDecodeRoundTrip() {
        let custom = PersonaProfile(name: "Test Persona", prompt: "Be helpful")
        store.personas = store.personas + [custom]

        let reloaded = store.personas
        XCTAssertTrue(reloaded.contains(where: { $0.id == custom.id }))
        XCTAssertEqual(reloaded.filter(\.isSystem).count, 2)
    }

    // MARK: - Active Persona

    func testActivePersonaReturnsNilWhenDisabled() throws {
        let persona = try XCTUnwrap(store.personas.first)
        store.activePersonaID = persona.id.uuidString
        store.personaRewriteEnabled = false
        XCTAssertNil(store.activePersona)
    }

    func testActivePersonaReturnsMatchWhenEnabled() throws {
        let persona = try XCTUnwrap(store.personas.first)
        store.activePersonaID = persona.id.uuidString
        store.personaRewriteEnabled = true
        XCTAssertEqual(store.activePersona?.id, persona.id)
    }

    // MARK: - applyPersonaSelection

    func testApplyPersonaSelectionWithNilDeactivates() {
        store.personaRewriteEnabled = true
        store.activePersonaID = UUID().uuidString

        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            expectation.fulfill()
        }

        store.applyPersonaSelection(nil)
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertFalse(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, "")
    }

    func testApplyPersonaSelectionWithUUIDActivates() {
        let id = UUID()

        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            expectation.fulfill()
        }

        store.applyPersonaSelection(id)
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, id.uuidString)
    }

    // MARK: - textLLMConfiguration

    func testTextLLMConfigurationUsesCurrentProvider() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.setLLMBaseURL("https://api.example.com/v1", for: .custom)
        store.setLLMModel("gpt-4", for: .custom)
        store.setLLMAPIKey("sk-test", for: .custom)

        let config = store.textLLMConfiguration()
        XCTAssertEqual(config.provider, .custom)
        XCTAssertEqual(config.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(config.model, "gpt-4")
        XCTAssertEqual(config.apiKey, "sk-test")
    }

    // MARK: - Per-provider LLM settings

    func testLLMBaseURLForCustomProviderFallsBackToLegacyKey() {
        defaults.set("https://legacy.example.com", forKey: "llm.baseURL")
        XCTAssertEqual(store.llmBaseURL(for: .custom), "https://legacy.example.com")
    }

    func testLLMBaseURLForNonCustomProviderUsesDefault() {
        let url = store.llmBaseURL(for: .openAI)
        XCTAssertEqual(url, LLMRemoteProvider.openAI.defaultBaseURL)
    }

    func testSetAndGetLLMBaseURLForProvider() {
        store.setLLMBaseURL("https://test.com", for: .deepSeek)
        XCTAssertEqual(store.llmBaseURL(for: .deepSeek), "https://test.com")
    }

    func testLLMModelForCustomProviderFallsBackToLegacyKey() {
        defaults.set("legacy-model", forKey: "llm.model")
        XCTAssertEqual(store.llmModel(for: .custom), "legacy-model")
    }

    func testLLMModelForNonCustomProviderUsesDefault() {
        let model = store.llmModel(for: .openAI)
        XCTAssertEqual(model, LLMRemoteProvider.openAI.defaultModel)
    }

    func testSetAndGetLLMModelForProvider() {
        store.setLLMModel("test-model", for: .anthropic)
        XCTAssertEqual(store.llmModel(for: .anthropic), "test-model")
    }

    func testLLMAPIKeyForCustomProviderFallsBackToLegacyKey() {
        defaults.set("legacy-key", forKey: "llm.apiKey")
        XCTAssertEqual(store.llmAPIKey(for: .custom), "legacy-key")
    }

    func testLLMAPIKeyForNonCustomProviderDefaultsToEmpty() {
        XCTAssertEqual(store.llmAPIKey(for: .openAI), "")
    }

    func testSetAndGetLLMAPIKeyForProvider() {
        store.setLLMAPIKey("sk-deep", for: .deepSeek)
        XCTAssertEqual(store.llmAPIKey(for: .deepSeek), "sk-deep")
    }
}

// MARK: - Extended SettingsStore tests

extension SettingsStoreTests {
    // MARK: - sttProvider

    func testSTTProviderDefaultsToWhisperAPI() {
        XCTAssertEqual(store.sttProvider, .whisperAPI)
    }

    func testSTTProviderCanBeChangedToAppleSpeech() {
        store.sttProvider = .appleSpeech
        XCTAssertEqual(store.sttProvider, .appleSpeech)
    }

    func testSTTProviderCanBeChangedToLocalModel() {
        store.sttProvider = .localModel
        XCTAssertEqual(store.sttProvider, .localModel)
    }

    func testSTTProviderCanBeChangedToDoubao() {
        store.sttProvider = .doubaoRealtime
        XCTAssertEqual(store.sttProvider, .doubaoRealtime)
    }

    // MARK: - llmProvider

    func testLLMProviderDefaultsToOpenAICompatible() {
        XCTAssertEqual(store.llmProvider, .openAICompatible)
    }

    // MARK: - appLanguage

    func testAppLanguagePersistence() {
        store.appLanguage = .japanese
        XCTAssertEqual(store.appLanguage, .japanese)

        store.appLanguage = .simplifiedChinese
        XCTAssertEqual(store.appLanguage, .simplifiedChinese)
    }

    // MARK: - textLLMConfiguration for various providers

    func testTextLLMConfigurationForOpenAI() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .openAI
        store.setLLMBaseURL("https://api.openai.com/v1", for: .openAI)
        store.setLLMModel("gpt-4o", for: .openAI)
        store.setLLMAPIKey("sk-openai", for: .openAI)

        let config = store.textLLMConfiguration()
        XCTAssertEqual(config.provider, .openAI)
        XCTAssertEqual(config.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(config.model, "gpt-4o")
    }

    func testTextLLMConfigurationForAnthropic() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .anthropic
        store.setLLMBaseURL("https://api.anthropic.com/v1", for: .anthropic)
        store.setLLMModel("claude-3-sonnet", for: .anthropic)

        let config = store.textLLMConfiguration()
        XCTAssertEqual(config.provider, .anthropic)
        XCTAssertEqual(config.model, "claude-3-sonnet")
    }

    // MARK: - hotkey settings

    func testActivationHotkeyRoundTrip() {
        let testHotkey = HotkeyBinding(keyCode: 49, modifierFlags: 0)
        store.activationHotkey = testHotkey
        let loaded = store.activationHotkey
        XCTAssertEqual(loaded.keyCode, 49)
    }

    func testActivationHotkeyDefaultIsFunctionKey() {
        let defaultHotkey = store.activationHotkey
        XCTAssertEqual(defaultHotkey.keyCode, HotkeyBinding.functionKeyCode)
    }

    func testAskHotkeyRoundTrip() {
        let testHotkey = HotkeyBinding(keyCode: 32, modifierFlags: 256)
        store.askHotkey = testHotkey
        XCTAssertEqual(store.askHotkey.keyCode, 32)
        XCTAssertEqual(store.askHotkey.modifierFlags, 256)
    }

    // MARK: - automaticVocabularyCollectionEnabled

    func testAutomaticVocabularyCollectionEnabledDefaultIsTrue() {
        XCTAssertTrue(store.automaticVocabularyCollectionEnabled)
    }

    func testAutomaticVocabularyCollectionEnabledToggle() {
        store.automaticVocabularyCollectionEnabled = false
        XCTAssertFalse(store.automaticVocabularyCollectionEnabled)
        store.automaticVocabularyCollectionEnabled = true
        XCTAssertTrue(store.automaticVocabularyCollectionEnabled)
    }

    // MARK: - useAppleSpeechFallback

    func testUseAppleSpeechFallbackDefaultIsFalse() {
        XCTAssertFalse(store.useAppleSpeechFallback)
    }

    func testUseAppleSpeechFallbackToggle() {
        store.useAppleSpeechFallback = true
        XCTAssertTrue(store.useAppleSpeechFallback)
        store.useAppleSpeechFallback = false
        XCTAssertFalse(store.useAppleSpeechFallback)
    }

    // MARK: - LLM config for all providers

    func testLLMBaseURLFallsBackToDefaultForAllProviders() {
        // freeModel uses runtime resolution and custom requires user configuration,
        // so only check providers that have static defaults
        for provider in LLMRemoteProvider.allCases where !provider.defaultBaseURL.isEmpty && provider != .custom {
            let url = store.llmBaseURL(for: provider)
            XCTAssertFalse(url.isEmpty, "\(provider) should fall back to a non-empty default base URL")
        }
    }

    func testLLMModelFallsBackToDefaultForProviderWithDefault() {
        let model = store.llmModel(for: .gemini)
        XCTAssertFalse(model.isEmpty || LLMRemoteProvider.gemini.defaultModel.isEmpty)
    }

    // MARK: - Per-provider settings independence

    func testOpenAIAndAnthropicSettingsAreIndependent() {
        store.setLLMModel("gpt-4o", for: .openAI)
        store.setLLMModel("claude-3", for: .anthropic)

        XCTAssertEqual(store.llmModel(for: .openAI), "gpt-4o")
        XCTAssertEqual(store.llmModel(for: .anthropic), "claude-3")
    }

    func testAPIKeyIsIndependentPerProvider() {
        store.setLLMAPIKey("sk-openai", for: .openAI)
        store.setLLMAPIKey("sk-anthropic", for: .anthropic)

        XCTAssertEqual(store.llmAPIKey(for: .openAI), "sk-openai")
        XCTAssertEqual(store.llmAPIKey(for: .anthropic), "sk-anthropic")
    }
}
