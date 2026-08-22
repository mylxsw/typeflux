import AppKit
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
        XCTAssertEqual(store.sttProvider, .localModel)
    }

    func testSetAndGetSTTProvider() {
        store.sttProvider = .localModel
        XCTAssertEqual(store.sttProvider, .localModel)
    }

    func testInvalidSTTProviderFallsBackToDefault() {
        defaults.set("nonexistent", forKey: "stt.provider")
        XCTAssertEqual(store.sttProvider, .localModel)
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
        XCTAssertEqual(store.appearanceMode, .system)
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
            queue: nil
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
            queue: nil
        ) { _ in
            notificationFired = true
        }

        store.appearanceMode = .dark
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(notificationFired)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Overlay Style

    func testDefaultOverlayStyle() {
        XCTAssertEqual(store.overlayStyle, .liquidGlass)
    }

    func testSetOverlayStyle() {
        store.overlayStyle = .classic
        XCTAssertEqual(store.overlayStyle, .classic)
    }

    func testInvalidOverlayStyleFallsBackToLiquidGlass() {
        defaults.set("nonexistent", forKey: "ui.overlayStyle")
        XCTAssertEqual(store.overlayStyle, .liquidGlass)
    }

    func testOverlayStyleChangePostsNotification() {
        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .overlayStyleDidChange,
            object: nil,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }

        store.overlayStyle = .classic
        wait(for: [expectation], timeout: 1.0)
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
        XCTAssertEqual(store.llmRemoteProvider, .openAI)
    }

    func testSetAndGetLLMRemoteProvider() {
        store.llmRemoteProvider = .openAI
        XCTAssertEqual(store.llmRemoteProvider, .openAI)
    }

    func testInvalidLLMRemoteProviderFallsBackToDefault() {
        defaults.set("nonexistent", forKey: "llm.remote.provider")
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

    func testPreferredMicrophoneChangePostsNotification() {
        let expectation = XCTestExpectation(description: "Preferred microphone notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .preferredMicrophoneDidChange,
            object: store,
            queue: nil
        ) { _ in
            expectation.fulfill()
        }

        store.preferredMicrophoneID = "BluetoothMic-1234"

        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testPreferredMicrophoneDoesNotNotifyWhenValueIsUnchanged() {
        store.preferredMicrophoneID = "BuiltInMic-1234"
        var notificationFired = false
        let observer = NotificationCenter.default.addObserver(
            forName: .preferredMicrophoneDidChange,
            object: store,
            queue: nil
        ) { _ in
            notificationFired = true
        }

        store.preferredMicrophoneID = "BuiltInMic-1234"

        XCTAssertFalse(notificationFired)
        NotificationCenter.default.removeObserver(observer)
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
            "https://api.openai.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(store.whisperModel),
            "gpt-4o-transcribe"
        )
    }

    func testResolvedDefaultWhisperConfigurationUsesXAIWhisperFallbackForXAIEndpoint() {
        store.whisperBaseURL = "https://api.x.ai/v1/audio/transcriptions"

        XCTAssertEqual(
            OpenAIAudioModelCatalog.resolvedWhisperModel(
                store.whisperModel,
                endpoint: store.whisperBaseURL
            ),
            "whisper-1"
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
        XCTAssertEqual(store.localSTTModel, .senseVoiceSmall)
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

    func testDefaultAliCloudModelUsesParaformerRealtimeV2() {
        XCTAssertEqual(store.aliCloudModel, "paraformer-realtime-v2")
    }

    func testSetAndGetAliCloudModel() {
        store.aliCloudModel = "fun-asr-realtime"
        XCTAssertEqual(store.aliCloudModel, "fun-asr-realtime")
    }

    func testEmptyAliCloudModelFallsBackToDefault() {
        store.aliCloudModel = "fun-asr-realtime"
        store.aliCloudModel = "   "
        XCTAssertEqual(store.aliCloudModel, "paraformer-realtime-v2")
    }

    func testAliCloudSuggestedModelsIncludeParaformerRealtimeV2() {
        XCTAssertEqual(AliCloudASRDefaults.suggestedModels.first, "paraformer-realtime-v2")
        XCTAssertTrue(AliCloudASRDefaults.suggestedModels.contains("fun-asr-realtime"))
        XCTAssertFalse(AliCloudASRDefaults.suggestedModels.contains("paraformer-realtime-8k-v2"))
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

    func testDefaultDoubaoResourceID() {
        XCTAssertEqual(store.doubaoResourceID, DoubaoASRDefaults.resourceID)
    }

    func testDoubaoResourceIDUsesDefaultValue() {
        defaults.set(DoubaoASRDefaults.resourceID, forKey: "stt.doubao.resourceID")
        XCTAssertEqual(store.doubaoResourceID, DoubaoASRDefaults.resourceID)
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

    func testDefaultQuickInputDisabled() {
        XCTAssertFalse(store.quickInputEnabled)
    }

    func testSetQuickInputEnabled() {
        store.quickInputEnabled = true
        XCTAssertTrue(store.quickInputEnabled)
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

    func testDefaultLocalSTTMemoryOptimizationDisabled() {
        XCTAssertFalse(store.localSTTMemoryOptimizationEnabled)
    }

    func testSetLocalSTTMemoryOptimizationDisabled() {
        store.localSTTMemoryOptimizationEnabled = false
        XCTAssertFalse(store.localSTTMemoryOptimizationEnabled)
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

    func testEffectivePersonaUsesAppBindingWhenDefaultPersonaIsDisabled() {
        let appSpecificPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it casual.")
        store.personas = store.personas + [appSpecificPersona]
        store.savePersonaAppBinding(appIdentifier: "com.tinyspeck.slackmacgap", personaID: appSpecificPersona.id)

        let effectivePersona = store.effectivePersona(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(effectivePersona?.id, appSpecificPersona.id)
    }

    func testEffectivePersonaUsesNoPersonaAppBindingOverDefaultPersona() throws {
        let defaultPersona = try XCTUnwrap(store.personas.first)
        store.applyPersonaSelection(defaultPersona.id)
        store.savePersonaAppBinding(appIdentifier: "com.tinyspeck.slackmacgap", personaID: nil)

        let effectivePersona = store.effectivePersona(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        XCTAssertNil(effectivePersona)
    }

    func testEffectivePersonaFallsBackToDefaultPersonaWhenNoAppBindingMatches() throws {
        let defaultPersona = try XCTUnwrap(store.personas.first)
        store.applyPersonaSelection(defaultPersona.id)
        let missingPersonaID = UUID()
        store.savePersonaAppBinding(appIdentifier: "com.tinyspeck.slackmacgap", personaID: missingPersonaID)

        let effectivePersona = store.effectivePersona(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        XCTAssertEqual(store.personaAppBindings.first?.personaID, missingPersonaID)
        XCTAssertEqual(effectivePersona?.id, defaultPersona.id)
    }

    func testEffectivePersonaIgnoresAppBindingsWhenFeatureIsPaused() throws {
        let defaultPersona = try XCTUnwrap(store.personas.first)
        let appSpecificPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it casual.")
        store.personas = store.personas + [appSpecificPersona]
        store.applyPersonaSelection(defaultPersona.id)
        store.savePersonaAppBinding(appIdentifier: "com.tinyspeck.slackmacgap", personaID: appSpecificPersona.id)
        store.personaAppBindingsEnabled = false

        let effectivePersona = store.effectivePersona(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(effectivePersona?.id, defaultPersona.id)
    }

    func testEffectivePersonaIgnoresNoPersonaBindingWhenFeatureIsPaused() throws {
        let defaultPersona = try XCTUnwrap(store.personas.first)
        store.applyPersonaSelection(defaultPersona.id)
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: nil)
        store.personaAppBindingsEnabled = false

        let effectivePersona = store.effectivePersona(
            appName: "Slack",
            bundleIdentifier: nil
        )

        XCTAssertEqual(effectivePersona?.id, defaultPersona.id)
    }

    func testSavePersonaAppBindingReplacesExistingIdentifierCaseInsensitively() {
        let firstPersona = store.personas[0]
        let secondPersona = store.personas[1]

        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: firstPersona.id)
        store.savePersonaAppBinding(appIdentifier: "slack", personaID: secondPersona.id)

        XCTAssertEqual(store.personaAppBindings.count, 1)
        XCTAssertEqual(store.personaAppBindings.first?.personaID, secondPersona.id)
        XCTAssertEqual(store.personaAppBindings.first?.appIdentifier, "slack")
    }

    func testSavePersonaAppBindingTrimsWhitespace() {
        let persona = store.personas[0]

        store.savePersonaAppBinding(appIdentifier: "  Slack  ", personaID: persona.id)

        XCTAssertEqual(store.personaAppBindings.first?.appIdentifier, "Slack")
    }

    func testEffectivePersonaIgnoresPausedAppBinding() throws {
        let defaultPersona = try XCTUnwrap(store.personas.first)
        let appSpecificPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it casual.")
        store.personas = store.personas + [appSpecificPersona]
        store.applyPersonaSelection(defaultPersona.id)
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: appSpecificPersona.id)
        let bindingID = try XCTUnwrap(store.personaAppBindings.first?.id)
        store.setPersonaAppBindingEnabled(id: bindingID, isEnabled: false)

        let effectivePersona = store.effectivePersona(
            appName: "Slack",
            bundleIdentifier: nil
        )

        XCTAssertEqual(effectivePersona?.id, defaultPersona.id)
    }

    func testActivePersonaAppBindingRequiresEnabledFeatureAndEnabledBinding() throws {
        let appSpecificPersona = PersonaProfile(name: "Chat Reply", prompt: "Keep it casual.")
        store.personas = store.personas + [appSpecificPersona]
        store.savePersonaAppBinding(appIdentifier: "com.tinyspeck.slackmacgap", personaID: appSpecificPersona.id)
        let bindingID = try XCTUnwrap(store.personaAppBindings.first?.id)

        XCTAssertEqual(
            store.activePersonaAppBinding(
                appName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap"
            )?.id,
            bindingID
        )

        store.setPersonaAppBindingEnabled(id: bindingID, isEnabled: false)
        XCTAssertNil(
            store.activePersonaAppBinding(
                appName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap"
            )
        )

        store.setPersonaAppBindingEnabled(id: bindingID, isEnabled: true)
        store.personaAppBindingsEnabled = false
        XCTAssertNil(
            store.activePersonaAppBinding(
                appName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap"
            )
        )
    }

    func testUpdatePersonaAppBindingPersonaUpdatesExistingBinding() {
        let firstPersona = store.personas[0]
        let secondPersona = store.personas[1]
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: firstPersona.id)
        let bindingID = store.personaAppBindings[0].id

        store.updatePersonaAppBindingPersona(id: bindingID, personaID: secondPersona.id)

        XCTAssertEqual(store.personaAppBindings.first?.id, bindingID)
        XCTAssertEqual(store.personaAppBindings.first?.personaID, secondPersona.id)
    }

    func testUpdatePersonaAppBindingPersonaCanDisablePersona() {
        let persona = store.personas[0]
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: persona.id)
        let bindingID = store.personaAppBindings[0].id

        store.updatePersonaAppBindingPersona(id: bindingID, personaID: nil)

        XCTAssertEqual(store.personaAppBindings.first?.id, bindingID)
        XCTAssertNil(store.personaAppBindings.first?.personaID)
    }

    func testUpdatePersonaAppBindingPersonaPreservesPausedState() {
        let firstPersona = store.personas[0]
        let secondPersona = store.personas[1]
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: firstPersona.id)
        let bindingID = store.personaAppBindings[0].id
        store.setPersonaAppBindingEnabled(id: bindingID, isEnabled: false)

        store.updatePersonaAppBindingPersona(id: bindingID, personaID: secondPersona.id)

        XCTAssertEqual(store.personaAppBindings.first?.personaID, secondPersona.id)
        XCTAssertFalse(store.personaAppBindings.first?.isEnabled ?? true)
    }

    func testSetPersonaAppBindingEnabledUpdatesExistingBinding() {
        let persona = store.personas[0]
        store.savePersonaAppBinding(appIdentifier: "Slack", personaID: persona.id)
        let bindingID = store.personaAppBindings[0].id

        store.setPersonaAppBindingEnabled(id: bindingID, isEnabled: false)

        XCTAssertFalse(store.personaAppBindings[0].isEnabled)
    }

    // MARK: - applyPersonaSelection

    func testApplyPersonaSelectionWithNilDeactivates() {
        store.personaRewriteEnabled = true
        store.activePersonaID = UUID().uuidString

        let expectation = XCTestExpectation(description: "Notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .personaSelectionDidChange,
            object: nil,
            queue: nil
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
            queue: nil
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

    func testSTTProviderDefaultsToLocalModel() {
        XCTAssertEqual(store.sttProvider, .localModel)
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
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.keyCode, 49)
    }

    func testActivationHotkeyDefaultIsFunctionKey() {
        let defaultHotkey = store.activationHotkey
        XCTAssertNotNil(defaultHotkey)
        XCTAssertEqual(defaultHotkey?.keyCode, HotkeyBinding.functionKeyCode)
    }

    func testAskHotkeyRoundTrip() {
        let testHotkey = HotkeyBinding(keyCode: 32, modifierFlags: 256)
        store.askHotkey = testHotkey
        XCTAssertNotNil(store.askHotkey)
        XCTAssertEqual(store.askHotkey?.keyCode, 32)
        XCTAssertEqual(store.askHotkey?.modifierFlags, 256)
    }

    func testHistoryHotkeyDefaultIsCommandOptionO() {
        let defaultHotkey = store.historyHotkey
        XCTAssertNotNil(defaultHotkey)
        XCTAssertEqual(defaultHotkey?.keyCode, HotkeyBinding.oKeyCode)
        XCTAssertEqual(defaultHotkey?.modifierFlags, UInt(NSEvent.ModifierFlags.command.union(.option).rawValue))
    }

    func testHistoryHotkeyRoundTrip() {
        let testHotkey = HotkeyBinding(keyCode: 45, modifierFlags: 256)
        store.historyHotkey = testHotkey
        XCTAssertEqual(store.historyHotkey?.keyCode, 45)
        XCTAssertEqual(store.historyHotkey?.modifierFlags, 256)
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

        // MARK: - Output OpenCC

        func testDefaultOutputOpenCCEnabled() {
            #if DEBUG
                XCTAssertTrue(store.outputOpenCCEnabled, "OpenCC should be enabled by default in debug builds")
            #else
                XCTAssertTrue(store.outputOpenCCEnabled, "OpenCC should be enabled by default in release builds")
            #endif
        }

        func testDefaultOutputOpenCCConfig() {
            XCTAssertEqual(
                store.outputOpenCCConfig,
                "s2twp",
                "Default config should be s2twp (Simplified to Traditional Taiwan)"
            )
        }

        func testSetOutputOpenCCEnabled() {
            store.outputOpenCCEnabled = false
            XCTAssertFalse(store.outputOpenCCEnabled)

            store.outputOpenCCEnabled = true
            XCTAssertTrue(store.outputOpenCCEnabled)
        }

        func testSetOutputOpenCCConfig() {
            store.outputOpenCCConfig = "s2tw"
            XCTAssertEqual(store.outputOpenCCConfig, "s2tw")

            store.outputOpenCCConfig = "t2s"
            XCTAssertEqual(store.outputOpenCCConfig, "t2s")

            store.outputOpenCCConfig = "s2twp"
            XCTAssertEqual(store.outputOpenCCConfig, "s2twp")
        }

        func testOutputOpenCCEnabledPersistence() {
            store.outputOpenCCEnabled = false

            // Create new store instance with same defaults
            let newStore = SettingsStore(defaults: defaults)
            XCTAssertFalse(newStore.outputOpenCCEnabled, "Setting should persist across store instances")
        }

        func testOutputOpenCCConfigPersistence() {
            store.outputOpenCCConfig = "t2s"

            // Create new store instance with same defaults
            let newStore = SettingsStore(defaults: defaults)
            XCTAssertEqual(newStore.outputOpenCCConfig, "t2s", "Config should persist across store instances")
        }
    }
}
