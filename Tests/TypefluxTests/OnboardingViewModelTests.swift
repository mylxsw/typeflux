@testable import Typeflux
import XCTest

final class OnboardingViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
        suiteName = "OnboardingViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        store.useAppleSpeechFallback = false
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        KeychainTokenStore.clearAll()
        KeychainTokenStore.useInMemoryStoreForTesting = false
        super.tearDown()
    }

    // MARK: - Steps

    @MainActor
    func testEveryoneWalksThroughEveryFeature() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.visibleSteps, [.welcome, .permissions, .voice, .launcher, .tools, .ring, .chat, .finish])
        XCTAssertEqual(viewModel.featureSteps.compactMap(\.feature), OnboardingFeature.allCases)
        XCTAssertEqual(viewModel.currentStep, .welcome)
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertFalse(viewModel.isLastStep)
        XCTAssertNil(OnboardingViewModel.Step.welcome.feature)
        XCTAssertNil(OnboardingViewModel.Step.finish.feature)
    }

    @MainActor
    func testAdvanceAndBackMoveBetweenSteps() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.permissions = grantedPermissions()

        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertEqual(viewModel.stepDirection, 1)
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .voice)

        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertEqual(viewModel.stepDirection, -1)
        viewModel.goBack()
        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    @MainActor
    func testGuidesNeverBlockAndTheLastStepCompletes() {
        var completions = 0
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: { completions += 1 })
        viewModel.currentStep = .voice

        for step in [OnboardingViewModel.Step.launcher, .tools, .ring, .chat, .finish] {
            XCTAssertTrue(viewModel.canAdvance)
            viewModel.advance()
            XCTAssertEqual(viewModel.currentStep, step)
        }
        XCTAssertTrue(viewModel.isLastStep)
        XCTAssertFalse(store.isOnboardingCompleted)

        viewModel.advance()
        XCTAssertTrue(store.isOnboardingCompleted)
        XCTAssertEqual(completions, 1)
        viewModel.advance()
        XCTAssertEqual(completions, 1, "Completing twice must not call back twice")
    }

    // MARK: - Guides

    @MainActor
    func testGuideShortcutsComeFromSettings() {
        store.askHotkey = .rightOptionAsk
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(
            viewModel.shortcuts(for: .launcher).first?.keys,
            HotkeyFormat.components(.rightOptionAsk)
        )
    }

    @MainActor
    func testVoicePracticeCountsOnlyRealText() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        XCTAssertFalse(viewModel.didPracticeVoice)

        viewModel.voicePracticeText = "  \n "
        XCTAssertFalse(viewModel.didPracticeVoice)

        viewModel.voicePracticeText = "Hello there"
        XCTAssertTrue(viewModel.didPracticeVoice)
    }

    // MARK: - Permissions

    @MainActor
    func testEveryFeaturesPermissionsAreAskedForTogether() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        XCTAssertEqual(viewModel.requiredPermissionIDs, [.microphone, .accessibility])

        store.useAppleSpeechFallback = true
        XCTAssertEqual(viewModel.requiredPermissionIDs, [.microphone, .speechRecognition, .accessibility])
    }

    @MainActor
    func testMissingPermissionsBlockContinueButLaterMovesOnToTheGuides() {
        var completions = 0
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: { completions += 1 })
        viewModel.currentStep = .permissions
        viewModel.permissions = [
            .init(id: .microphone, state: .needsAttention, detail: "Missing"),
            .init(id: .accessibility, state: .granted, detail: "Granted")
        ]

        XCTAssertEqual(viewModel.missingPermissionCount, 1)
        XCTAssertEqual(viewModel.requiredPermissions.map(\.id), [.microphone, .accessibility])
        XCTAssertFalse(viewModel.canAdvance)
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .permissions)

        viewModel.skipPermissions()
        XCTAssertEqual(viewModel.currentStep, .voice, "Later skips the permissions, not the guides")
        XCTAssertFalse(store.isOnboardingCompleted)
        XCTAssertEqual(completions, 0)
    }

    @MainActor
    func testSkipPermissionsOnlyWorksOnPermissionsStep() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.skipPermissions()

        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    // MARK: - Globe key

    @MainActor
    func testGlobeKeySetupShowsOnlyWhileFnIsBlocked() {
        let reader = StubGlobeKeyPreferenceReader(usage: .showEmojiAndSymbols)
        let viewModel = OnboardingViewModel(settingsStore: store, globeKeyReader: reader, onComplete: {})
        XCTAssertTrue(viewModel.needsGlobeKeySetup)

        viewModel.useExternalKeyboardShortcutReplacement(.rightCommand)
        XCTAssertFalse(viewModel.needsGlobeKeySetup, "A right-hand key replaces fn")

        viewModel.restoreDefaultFNShortcuts()
        XCTAssertTrue(viewModel.needsGlobeKeySetup)
        reader.usage = .doNothing
        viewModel.refreshGlobeKeyState()
        XCTAssertFalse(viewModel.needsGlobeKeySetup)
    }

    @MainActor
    func testKeyboardSystemSettingsURLPointsToKeyboardPane() {
        let url = OnboardingViewModel.keyboardSystemSettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(url.absoluteString.contains("Keyboard"))
    }

    @MainActor
    func testIsGlobeKeyReadyReflectsReaderState() {
        let reader = StubGlobeKeyPreferenceReader(usage: .changeInputSource)
        let viewModel = OnboardingViewModel(settingsStore: store, globeKeyReader: reader, onComplete: {})
        XCTAssertFalse(viewModel.isGlobeKeyReady)

        reader.usage = .doNothing
        viewModel.refreshGlobeKeyState()
        XCTAssertTrue(viewModel.isGlobeKeyReady)

        reader.usage = nil
        viewModel.refreshGlobeKeyState()
        XCTAssertFalse(viewModel.isGlobeKeyReady, "Unknown usage is not ready")
    }

    @MainActor
    func testExternalKeyboardReplacementPersistsAndRestores() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.useExternalKeyboardShortcutReplacement(.rightOption)
        XCTAssertEqual(viewModel.externalKeyboardShortcutReplacement, .rightOption)
        XCTAssertEqual(store.activationHotkey?.signature, HotkeyBinding.rightOptionActivation.signature)
        XCTAssertEqual(store.askHotkey?.signature, HotkeyBinding.rightOptionAsk.signature)
        XCTAssertTrue(viewModel.showShortcutReplacementAppliedAlert)

        viewModel.showShortcutReplacementAppliedAlert = false
        viewModel.restoreDefaultFNShortcuts()
        XCTAssertNil(viewModel.externalKeyboardShortcutReplacement)
        XCTAssertEqual(store.activationHotkey?.signature, HotkeyBinding.defaultActivation.signature)
        XCTAssertEqual(store.askHotkey?.signature, HotkeyBinding.defaultAsk.signature)
        XCTAssertTrue(viewModel.showShortcutReplacementAppliedAlert)
    }

    @MainActor
    func testInitialExternalKeyboardReplacementReflectsStoredShortcuts() {
        store.activationHotkey = .rightCommandActivation
        store.askHotkey = .rightCommandAsk

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.externalKeyboardShortcutReplacement, .rightCommand)
    }

    @MainActor
    func testWelcomeKeysComeFromSettings() {
        store.askHotkey = .rightOptionAsk
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.launcherHotkey?.signature, HotkeyBinding.rightOptionAsk.signature)
        XCTAssertEqual(viewModel.ringHotkey?.signature, RingConfiguration.defaultHotkey.signature)
    }

    // MARK: - Speech model

    @MainActor
    func testLeavingWelcomeStartsSpeechModelDownload() async {
        let manager = StubLocalModelManager()
        let prepared = expectation(description: "model prepared")
        manager.onPrepare = { prepared.fulfill() }
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})

        viewModel.advance()
        await fulfillment(of: [prepared], timeout: 2)

        XCTAssertEqual(manager.preparedConfigurations.map(\.model), [store.localSTTModel])
    }

    @MainActor
    func testLaterStepsDoNotStartTheDownload() {
        let manager = StubLocalModelManager()
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})
        viewModel.currentStep = .voice

        viewModel.advance()

        XCTAssertTrue(manager.preparedConfigurations.isEmpty)
    }

    @MainActor
    func testAvailableModelIsNotDownloadedAgain() {
        let manager = StubLocalModelManager()
        manager.available = true
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})

        viewModel.advance()

        XCTAssertTrue(manager.preparedConfigurations.isEmpty)
    }

    // MARK: - Completion side effects

    @MainActor
    func testCompletingWithConfiguredLLMSelectsTypefluxPersona() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.setLLMBaseURL("https://example.com/v1", for: .custom)
        store.setLLMModel("my-model", for: .custom)
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        finish(viewModel)

        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    @MainActor
    func testCompletingWithoutLLMLeavesPersonaDisabled() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        finish(viewModel)

        XCTAssertFalse(store.personaRewriteEnabled)
        XCTAssertNil(store.activePersona)
    }

    @MainActor
    func testSkipWithoutAnimationMarksCompleted() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.skipWithoutAnimation()

        XCTAssertTrue(store.isOnboardingCompleted)
    }

    // MARK: - Analytics

    @MainActor
    func testAnalyticsReportsEveryStepAndCompletion() {
        let recorder = AnalyticsEventRecorder()
        var now = Date(timeIntervalSince1970: 1000)
        let viewModel = OnboardingViewModel(
            settingsStore: store, analyticsReporter: recorder, now: { now }, onComplete: {}
        )
        viewModel.permissions = grantedPermissions()
        viewModel.voicePracticeText = "Hi"

        for _ in viewModel.visibleSteps.dropLast() {
            viewModel.advance()
        }
        now = Date(timeIntervalSince1970: 1012)
        viewModel.advance()

        let steps = recorder.events.filter { $0.name == "onboarding_step_completed" }.compactMap { $0.properties["step"] }
        XCTAssertEqual(steps, ["welcome", "permissions", "voice", "launcher", "tools", "ring", "chat", "finish"])
        XCTAssertEqual(recorder.events.last?.name, "onboarding_completed")
        XCTAssertEqual(recorder.events.last?.properties, [
            "duration_seconds": "12", "missing_permissions": "0", "practiced_voice": "true"
        ])
    }

    @MainActor
    func testAnalyticsReportsSkippedPermissionsAndAbandonmentOnce() {
        let recorder = AnalyticsEventRecorder()
        let viewModel = OnboardingViewModel(settingsStore: store, analyticsReporter: recorder, onComplete: {})
        viewModel.currentStep = .permissions
        viewModel.permissions = [.init(id: .microphone, state: .needsAttention, detail: "Missing")]

        viewModel.skipPermissions()
        viewModel.skipWithoutAnimation()
        viewModel.skipWithoutAnimation()

        XCTAssertEqual(recorder.events.map(\.name), ["onboarding_step_completed", "onboarding_abandoned"])
        XCTAssertEqual(recorder.events[0].properties, ["step": "permissions", "skipped": "true"])
        XCTAssertEqual(recorder.events[1].properties, ["last_step": "voice"])
    }

    // MARK: - Helpers

    @MainActor
    private func finish(_ viewModel: OnboardingViewModel) {
        viewModel.currentStep = .finish
        viewModel.advance()
        XCTAssertTrue(store.isOnboardingCompleted)
    }

    private func grantedPermissions() -> [PrivacyGuard.PermissionSnapshot] {
        PrivacyGuard.PermissionID.allCases.map { .init(id: $0, state: .granted, detail: "Granted") }
    }
}

private final class StubGlobeKeyPreferenceReader: GlobeKeyPreferenceReading {
    var usage: GlobeKeyUsage?

    init(usage: GlobeKeyUsage?) {
        self.usage = usage
    }

    func currentUsage() -> GlobeKeyUsage? {
        usage
    }
}

private final class StubLocalModelManager: LocalSTTModelManaging, @unchecked Sendable {
    var onPrepare: (() -> Void)?
    var available = false

    private let lock = NSLock()
    private var _preparedConfigurations: [LocalSTTConfiguration] = []

    var preparedConfigurations: [LocalSTTConfiguration] {
        lock.withLock { _preparedConfigurations }
    }

    func prepareModel(
        settingsStore: SettingsStore,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        try await prepareModel(configuration: LocalSTTConfiguration(settingsStore: settingsStore), onUpdate: onUpdate)
    }

    func prepareModel(
        configuration: LocalSTTConfiguration,
        onUpdate: (@Sendable (LocalSTTPreparationUpdate) -> Void)?
    ) async throws {
        lock.withLock { _preparedConfigurations.append(configuration) }
        onUpdate?(LocalSTTPreparationUpdate(
            message: "Preparing", progress: 0.5, storagePath: storagePath(for: configuration), source: "Test"
        ))
        onPrepare?()
    }

    func preparedModelInfo(settingsStore _: SettingsStore) -> LocalSTTPreparedModelInfo? {
        nil
    }

    func isModelAvailable(_: LocalSTTModel) -> Bool {
        available
    }

    func deleteModelFiles(_: LocalSTTModel) throws {}

    func storagePath(for configuration: LocalSTTConfiguration) -> String {
        "/tmp/\(configuration.model.rawValue)"
    }
}
