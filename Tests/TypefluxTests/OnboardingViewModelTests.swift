import AppKit
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct OnboardingViewModelTests {
    private func fixture(_ check: (SettingsStore, OnboardingViewModel, OnboardingTestModelManager) async throws
        -> Void) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let manager = OnboardingTestModelManager()
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let model = OnboardingViewModel(settingsStore: settings, modelLibrary: library,
                                            globeKeyReader: OnboardingReadyGlobeKey(), localModelManager: manager,
                                            onComplete: {})
            try await check(settings, model, manager)
        }
    }

    @Test func `skip cancels pending navigation and explains each affected capability`() async throws {
        try await fixture { _, model, _ in
            model.chooseRoute(.custom)
            for (step, target) in [
                (OnboardingViewModel.Step.cloud, OnboardingViewModel.SkipTarget.allModels),
                (.speech, .speech), (.llm, .language)
            ] {
                model.currentStep = step
                model.requestSetupSkip()
                #expect(model.skipConfirmation == target)
                #expect(!model.skipMessage(for: target).isEmpty)
                model.skipConfirmation = nil
            }
        }
    }

    @Test func `changing speech service invalidates the inline test and preserves deferral`() async throws {
        try await fixture { settings, model, _ in
            settings.onboardingSpeechDeferred = true
            settings.whisperAPIKey = "fixture-key"
            model.chooseRoute(.custom)
            model.currentStep = .speech
            model.speechModel.testStatus = .success(preview: "OK", latencyMs: 1)
            model.speechModel.canContinue = true
            model.speechModel.selectProvider(.whisperAPI)
            #expect(model.speechModel.testStatus == .idle)
            #expect(settings.sttProvider == .whisperAPI)
            #expect(settings.onboardingSpeechDeferred)
            #expect(!model.canAdvance)
        }
    }

    @Test func `model setup precedes permissions`() async throws {
        try await fixture { _, model, _ in
            model.chooseRoute(.custom)
            #expect(Array(model.visibleSteps.prefix(5)) == [.welcome, .route, .speech, .llm, .permissions])
            model.advance()
            #expect(model.currentStep == .route)
            model.advance()
            #expect(model.currentStep == .speech)
        }
    }

    @Test func `cloud is recommended but login is not bypassed`() async throws {
        try await fixture { _, model, _ in
            #expect(model.serviceRoute == .cloud)
            model.currentStep = .cloud
            #expect(!model.canAdvance)
            model.advance()
            #expect(model.currentStep == .cloud)
        }
    }

    @Test func `launcher only requires explicit skip and does not prepare models`() async throws {
        try await fixture { settings, model, manager in
            model.currentStep = .route
            model.skipConfirmation = .allModels
            #expect(!settings.onboardingSpeechDeferred)
            model.confirmSkip()
            #expect(model.serviceRoute == .launcherOnly)
            #expect(model.currentStep == .permissions)
            #expect(settings.onboardingSpeechDeferred && settings.onboardingAIDeferred)
            #expect(model.visibleSteps.suffix(3) == [.permissions, .shortcuts, .try])
            #expect(model.requiredPermissionIDs == [.accessibility])
            #expect(manager.prepareCount == 0)
        }
    }

    @Test func `no download starts on welcome`() async throws {
        try await fixture { _, model, manager in
            model.advance()
            #expect(manager.prepareCount == 0)
        }
    }

    @Test func `speech continuation follows the inline page readiness`() async throws {
        try await fixture { _, model, _ in
            model.chooseRoute(.custom); model.currentStep = .speech
            #expect(!model.canAdvance)
            model.advance()
            #expect(model.currentStep == .speech)
            model.speechModel.canContinue = true
            #expect(model.canAdvance)
            model.advance()
            #expect(model.currentStep == .llm)
        }
    }

    @Test func `skipping speech still offers AI configuration`() async throws {
        try await fixture { settings, model, _ in
            model.chooseRoute(.custom); model.currentStep = .speech
            model.skipConfirmation = .speech; model.confirmSkip()
            #expect(model.currentStep == .llm)
            #expect(settings.onboardingSpeechDeferred)
            #expect(model.visibleSteps.contains(.try))
            #expect(model.requiredPermissionIDs == [.microphone, .accessibility])
        }
    }

    @Test func `skipping AI keeps ordinary dictation`() async throws {
        try await fixture { settings, model, manager in
            manager.available = true
            model.chooseRoute(.custom); model.currentStep = .llm
            model.skipConfirmation = .language; model.confirmSkip()
            #expect(model.currentStep == .permissions)
            #expect(settings.onboardingAIDeferred)
            #expect(model.visibleSteps.contains(.try))
            #expect(model.visibleSteps.contains(.shortcuts))
            #expect(model.tryModel.isVoiceConnected)
        }
    }

    @Test func `permission counts and skip impacts use the same requirements as the visible page`() async throws {
        try await fixture { settings, model, _ in
            model.chooseRoute(.custom)
            model.speechSkipped = true
            model.permissions = [.init(id: .accessibility, state: .granted, detail: "")]
            #expect(model.requiredPermissionIDs == [.microphone, .accessibility])
            #expect(model.missingPermissionCount == 1)
            #expect(model.skipMessage(for: .permissions).contains(L("setup.permission.microphone.impact")))
            settings.sttProvider = .appleSpeech
            #expect(model.requiredPermissionIDs == [.microphone, .accessibility, .speechRecognition])
            #expect(model.missingPermissionCount == 2)
            #expect(model.skipMessage(for: .permissions).contains(L("setup.permission.speechRecognition.impact")))
            model.chooseRoute(.launcherOnly)
            #expect(model.requiredPermissionIDs == [.accessibility])
            #expect(model.missingPermissionCount == 0)
        }
    }

    @Test func `permission deferral requires confirmation`() async throws {
        try await fixture { _, model, manager in
            manager.available = true
            model.chooseRoute(.custom); model.currentStep = .permissions
            model.permissions = [.init(id: .microphone, state: .needsAttention, detail: "Missing")]
            #expect(!model.canAdvance)
            model.skipPermissions()
            #expect(model.currentStep == .permissions)
            #expect(model.skipConfirmation == .permissions)
            model.confirmSkip()
            #expect(model.currentStep == .shortcuts)
        }
    }

    @Test func `typing in practice is not A successful voice test`() async throws {
        try await fixture { _, model, _ in
            model.voicePracticeText = "Typed by hand"
            #expect(!model.didPracticeVoice)
        }
    }

    @Test func `practice needs A successful applied recording`() async throws {
        try await fixture { _, model, _ in
            let history = OnboardingTestHistoryStore()
            model.historyStore = history; model.currentStep = .try
            model.voicePracticeBeganAt = .distantPast
            model.voicePracticeText = "Hello"
            history.records = [HistoryRecord(date: Date(), transcriptText: "Hello", recordingStatus: .succeeded,
                                             transcriptionStatus: .succeeded, processingStatus: .succeeded,
                                             applyStatus: .failed)]
            model.updateVoicePractice()
            #expect(!model.didPracticeVoice)
            history.records[0].applyStatus = .succeeded
            model.updateVoicePractice()
            #expect(model.didPracticeVoice)
        }
    }

    @Test func `finish does not require skipped configuration`() async throws {
        try await fixture { settings, model, _ in
            model.skipConfirmation = .allModels; model.confirmSkip()
            model.currentStep = .try; model.advance()
            #expect(settings.isOnboardingCompleted)
            #expect(settings.onboardingAIDeferred)
        }
    }

    @Test func `skipping keeps existing working configurations available`() async throws {
        try await fixture { _, model, manager in
            manager.available = true
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(
                id: $0,
                state: .granted,
                detail: "Granted"
            ) }
            try model.modelLibrary.save(
                .init(id: "test", name: "Local", baseURL: "http://localhost:1234/v1", model: "test"),
                key: ""
            )
            let reference = try #require(model.modelLibrary.firstLocalReference(hasImage: false))
            model.modelLibrary.rewriteReference = reference
            model.modelLibrary.defaultReference = reference
            #expect(model.skipMessage(for: .allModels) == L("setup.skip.existingModels"))
            model.skipConfirmation = .allModels; model.confirmSkip()
            #expect(model.voiceReady)
            #expect(model.languageConfigured)
            #expect(model.visibleSteps.contains(.try))
            #expect(model.visibleSteps.contains(.shortcuts))
        }
    }

    @Test func `skipping keyboard setup explains why voice shortcut is not ready`() async throws {
        try await fixture { _, model, manager in
            manager.available = true
            model.isGlobeKeyReady = false
            #expect(model.activationHotkey.signature == HotkeyBinding.defaultActivation.signature)
            model.permissions = PrivacyGuard.PermissionID.allCases.map { .init(
                id: $0, state: .granted, detail: "Granted"
            ) }
            model.currentStep = .permissions
            #expect(model.needsGlobeKeySetup)
            model.permissionsModel.canContinue = true
            #expect(model.canAdvance)
            model.skipConfirmation = .permissions; model.confirmSkip()
            #expect(!model.voiceReady)
            model.useExternalKeyboardShortcutReplacement(.rightCommand)
            #expect(model.voiceReady)
        }
    }

    @Test func `skipping AI without login does not enable an automatic rewrite persona`() async throws {
        try await fixture { settings, model, _ in
            settings.llmRemoteProvider = .typefluxCloud
            #expect(settings.isLLMConfigured)
            model.aiSkipped = true; model.currentStep = .try; model.advance()
            #expect(!settings.personaRewriteEnabled)
            #expect(settings.onboardingAIDeferred)
        }
    }

    @Test func `configuring models later clears AI deferral`() async throws {
        try await fixture { settings, model, _ in
            settings.onboardingAIDeferred = true
            try model.modelLibrary.save(
                .init(id: "test", name: "Local", baseURL: "http://localhost:1234/v1", model: "test"), key: ""
            )
            let reference = try #require(model.modelLibrary.firstLocalReference(hasImage: false))
            model.modelLibrary.rewriteReference = reference
            model.modelLibrary.defaultReference = reference
            #expect(!settings.onboardingAIDeferred)
        }
    }

    @Test func `back follows the selected service route`() async throws {
        try await fixture { _, model, _ in
            model.chooseRoute(.custom); model.advance(); model.advance()
            #expect(model.currentStep == .speech)
            model.goBack()
            #expect(model.currentStep == .route)
            model.chooseRoute(.cloud); model.advance()
            #expect(model.currentStep == .cloud)
            model.goBack(); model.goBack()
            #expect(model.currentStep == .welcome)
        }
    }

    @Test func `completion and abandonment analytics are reported once`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let recorder = AnalyticsEventRecorder()
            let model = OnboardingViewModel(settingsStore: settings, analyticsReporter: recorder, onComplete: {})
            model.currentStep = .route
            model.skipConfirmation = .allModels; model.confirmSkip()
            #expect(recorder.events.last?.properties == ["step": "route", "skipped": "true"])
            model.currentStep = .try; model.advance(); model.advance()
            #expect(recorder.events.count(where: { $0.name == "onboarding_completed" }) == 1)
            #expect(settings.isOnboardingCompleted)

            let abandoned = AnalyticsEventRecorder()
            let other = OnboardingViewModel(settingsStore: settings, analyticsReporter: abandoned, onComplete: {})
            other.skipWithoutAnimation(); other.skipWithoutAnimation()
            #expect(abandoned.events.map(\.name) == ["onboarding_abandoned"])
        }
    }

    @Test func `speech preflight distinguishes missing keys and paid cloud access`() async throws {
        try await fixture { settings, _, _ in
            settings.sttProvider = .whisperAPI
            #expect(FeatureSetupStatus.speechReason(
                settings: settings,
                loggedIn: false,
                cloudAllowed: false,
                localAvailable: false,
                googleAuthorized: false
            ) != nil)
            settings.sttProvider = .typefluxOfficial
            #expect(FeatureSetupStatus.speechReason(
                settings: settings,
                loggedIn: true,
                cloudAllowed: false,
                localAvailable: false,
                googleAuthorized: false
            ) != nil)
            #expect(FeatureSetupStatus.speechReason(settings: settings, loggedIn: true,
                                                    cloudAllowed: true, localAvailable: false,
                                                    googleAuthorized: false) ==
                    nil)
        }
    }

    @Test func `cloud selection checks access and assigns both models`() async throws {
        try await fixture { settings, _, manager in
            let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                                 loadStoredUserProfile: { nil }, saveStoredToken: { _, _ in },
                                 saveStoredUserProfile: { _ in },
                                 clearStoredSession: {}, fetchSubscription: { _ in .none })
            auth.isLoggedIn = true
            auth.subscription = BillingSubscriptionSnapshot(planCode: "pro", status: "active",
                                                            currentPeriodStart: nil, currentPeriodEnd: nil,
                                                            cancelAtPeriodEnd: false,
                                                            entitled: true, paid: true, cloudASRAllowed: true)
            let library = AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false)
            let model = OnboardingViewModel(settingsStore: settings, authState: auth, modelLibrary: library,
                                            localModelManager: manager, onComplete: {})
            model.currentStep = .cloud
            #expect(!model.canAdvance)
            model.cloudModel.canContinue = true
            #expect(model.canAdvance)
            model.advance()
            #expect(model.currentStep == .permissions)
            #expect(settings.sttProvider == .typefluxOfficial)
            #expect(library.defaultReference == "cloud:default")
            #expect(library.rewriteReference == "cloud:default")
            #expect(model.languageConfigured)
        }
    }

    @Test func `shortcut replacement and language still persist`() async throws {
        try await fixture { settings, model, _ in
            model.useExternalKeyboardShortcutReplacement(.rightCommand)
            #expect(settings.activationHotkey?.signature == HotkeyBinding.rightCommandActivation.signature)
            model.restoreDefaultFNShortcuts()
            #expect(settings.activationHotkey?.signature == HotkeyBinding.defaultActivation.signature)
            model.setLanguage(.simplifiedChinese)
            #expect(settings.appLanguage == .simplifiedChinese)
        }
    }
}

final class OnboardingTestModelManager: LocalSTTModelManaging, @unchecked Sendable {
    var available = false
    var prepareCount = 0
    func prepareModel(
        settingsStore _: SettingsStore,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        prepareCount += 1
    }

    func prepareModel(
        configuration _: LocalSTTConfiguration,
        onUpdate _: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        prepareCount += 1
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        available
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}
    func storagePath(for _: LocalSTTConfiguration) -> String {
        "/tmp/onboarding-fixture"
    }
}

struct OnboardingReadyGlobeKey: GlobeKeyPreferenceReading {
    func currentUsage() -> GlobeKeyUsage? {
        .doNothing
    }
}

final class OnboardingTestHistoryStore: HistoryStore {
    var records: [HistoryRecord] = []
    func save(record: HistoryRecord) {
        records.append(record)
    }

    func list() -> [HistoryRecord] {
        records
    }

    func list(limit: Int, offset: Int,
              searchQuery _: String?) -> [HistoryRecord] {
        Array(records.dropFirst(offset).prefix(limit))
    }

    func record(id: UUID) -> HistoryRecord? {
        records.first { $0.id == id }
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
    }

    func purge(olderThanDays _: Int) {}
    func clear() {
        records = []
    }

    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/onboarding-fixture.md")
    }
}
