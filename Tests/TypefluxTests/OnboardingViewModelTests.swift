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
    func testStepsAreWelcomeGoalsPermissions() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.visibleSteps, [.welcome, .goals, .permissions])
        XCTAssertEqual(viewModel.currentStep, .welcome)
        XCTAssertFalse(viewModel.canGoBack)
        XCTAssertFalse(viewModel.isLastStep)
    }

    @MainActor
    func testAdvanceAndBackMoveBetweenSteps() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .goals)
        XCTAssertEqual(viewModel.stepDirection, 1)
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertTrue(viewModel.isLastStep)

        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .goals)
        XCTAssertEqual(viewModel.stepDirection, -1)
        viewModel.goBack()
        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .welcome)
    }

    // MARK: - Goals

    @MainActor
    func testNewUserStartsWithDefaultGoals() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.goals, OnboardingGoal.defaultSelection)
        XCTAssertEqual(viewModel.orderedGoals, [.voice, .launcher, .chat])
        XCTAssertEqual(viewModel.estimatedMinutes, 5)
    }

    @MainActor
    func testStoredGoalsAreRestored() {
        store.onboardingGoals = [.ring, .tools]

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.orderedGoals, [.tools, .ring])
    }

    @MainActor
    func testEmptyStoredGoalsFallBackToDefaults() {
        store.onboardingGoals = []

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.goals, OnboardingGoal.defaultSelection)
    }

    @MainActor
    func testToggleGoalAndEmptySelectionBlocksAdvance() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.currentStep = .goals

        for goal in OnboardingGoal.defaultSelection {
            viewModel.toggleGoal(goal)
        }
        XCTAssertTrue(viewModel.goals.isEmpty)
        XCTAssertFalse(viewModel.canAdvance)
        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .goals)

        viewModel.toggleGoal(.ring)
        XCTAssertEqual(viewModel.goals, [.ring])
        XCTAssertTrue(viewModel.canAdvance)
    }

    @MainActor
    func testToggleAllSelectsEverythingThenRestoresDefaults() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.toggleAllGoals()
        XCTAssertTrue(viewModel.allGoalsSelected)
        XCTAssertEqual(viewModel.estimatedMinutes, 8)

        viewModel.toggleAllGoals()
        XCTAssertEqual(viewModel.goals, OnboardingGoal.defaultSelection)
        XCTAssertFalse(viewModel.allGoalsSelected)
    }

    // MARK: - Permissions

    @MainActor
    func testRequiredPermissionsFollowGoals() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        XCTAssertEqual(viewModel.requiredPermissionIDs, [.microphone, .accessibility])

        viewModel.toggleGoal(.voice)
        viewModel.toggleGoal(.launcher)
        XCTAssertEqual(viewModel.requiredPermissionIDs, [.microphone], "Chat alone only needs the microphone")

        viewModel.toggleGoal(.chat)
        viewModel.toggleGoal(.tools)
        XCTAssertTrue(viewModel.requiredPermissionIDs.isEmpty)
        XCTAssertTrue(viewModel.allRequiredPermissionsGranted)
    }

    @MainActor
    func testPermissionChipsListThePickedGoalsThatNeedIt() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.toggleGoal(.ring)

        XCTAssertEqual(viewModel.goals(using: .accessibility), [.voice, .launcher, .ring])
        XCTAssertEqual(viewModel.goals(using: .microphone), [.voice, .chat])
    }

    @MainActor
    func testMissingPermissionsBlockFinishButLaterCompletes() {
        var completions = 0
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: { completions += 1 })
        viewModel.currentStep = .permissions
        viewModel.permissions = [
            .init(id: .microphone, state: .needsAttention, detail: "Missing"),
            .init(id: .accessibility, state: .granted, detail: "Granted")
        ]

        XCTAssertEqual(viewModel.missingPermissionCount, 1)
        XCTAssertEqual(viewModel.requiredPermissions.map(\.id), [.microphone, .accessibility])
        viewModel.advance()
        XCTAssertFalse(store.isOnboardingCompleted)
        XCTAssertEqual(completions, 0)

        viewModel.finishLater()
        XCTAssertTrue(store.isOnboardingCompleted)
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testFinishLaterOnlyWorksOnPermissionsStep() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.finishLater()

        XCTAssertFalse(store.isOnboardingCompleted)
    }

    @MainActor
    func testGrantedPermissionsFinishAndPersistGoals() {
        var completions = 0
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: { completions += 1 })
        viewModel.toggleGoal(.tools)
        viewModel.currentStep = .permissions
        viewModel.permissions = grantedPermissions()

        viewModel.advance()

        XCTAssertTrue(store.isOnboardingCompleted)
        XCTAssertEqual(store.onboardingGoals, [.voice, .launcher, .tools, .chat])
        XCTAssertEqual(completions, 1)
        viewModel.advance()
        XCTAssertEqual(completions, 1, "Completing twice must not call back twice")
    }

    // MARK: - Globe key

    @MainActor
    func testGlobeKeySetupShowsOnlyForVoiceWithBlockedFnKey() {
        let reader = StubGlobeKeyPreferenceReader(usage: .showEmojiAndSymbols)
        let viewModel = OnboardingViewModel(settingsStore: store, globeKeyReader: reader, onComplete: {})
        XCTAssertTrue(viewModel.needsGlobeKeySetup)

        viewModel.toggleGoal(.voice)
        XCTAssertFalse(viewModel.needsGlobeKeySetup, "No voice input, no fn key requirement")

        viewModel.toggleGoal(.voice)
        viewModel.useExternalKeyboardShortcutReplacement(.rightCommand)
        XCTAssertFalse(viewModel.needsGlobeKeySetup, "A right-hand key replaces fn")

        viewModel.restoreDefaultFNShortcuts()
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
    func testLeavingGoalsWithVoiceStartsSpeechModelDownload() async {
        let manager = StubLocalModelManager()
        let prepared = expectation(description: "model prepared")
        manager.onPrepare = { prepared.fulfill() }
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})
        viewModel.currentStep = .goals

        viewModel.advance()
        await fulfillment(of: [prepared], timeout: 2)

        XCTAssertEqual(manager.preparedConfigurations.map(\.model), [store.localSTTModel])
    }

    @MainActor
    func testLeavingGoalsWithoutVoiceDoesNotDownload() {
        let manager = StubLocalModelManager()
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})
        viewModel.toggleGoal(.voice)
        viewModel.currentStep = .goals

        viewModel.advance()

        XCTAssertTrue(manager.preparedConfigurations.isEmpty)
    }

    @MainActor
    func testAvailableModelIsNotDownloadedAgain() {
        let manager = StubLocalModelManager()
        manager.available = true
        store.sttProvider = .localModel
        let viewModel = OnboardingViewModel(settingsStore: store, localModelManager: manager, onComplete: {})
        viewModel.currentStep = .goals

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
    func testSkipWithoutAnimationMarksCompletedAndKeepsGoals() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.toggleGoal(.ring)

        viewModel.skipWithoutAnimation()

        XCTAssertTrue(store.isOnboardingCompleted)
        XCTAssertEqual(store.onboardingGoals, [.voice, .launcher, .ring, .chat])
    }

    // MARK: - Analytics

    @MainActor
    func testAnalyticsReportsStepsGoalsAndCompletion() {
        let recorder = AnalyticsEventRecorder()
        var now = Date(timeIntervalSince1970: 1000)
        let viewModel = OnboardingViewModel(
            settingsStore: store, analyticsReporter: recorder, now: { now }, onComplete: {}
        )

        viewModel.advance()
        viewModel.advance()
        viewModel.permissions = grantedPermissions()
        now = Date(timeIntervalSince1970: 1012)
        viewModel.advance()

        XCTAssertEqual(recorder.events.map(\.name), [
            "onboarding_step_completed", "onboarding_step_completed", "onboarding_goal_selected",
            "onboarding_step_completed", "onboarding_completed"
        ])
        XCTAssertEqual(recorder.events[0].properties, ["step": "welcome", "skipped": "false"])
        XCTAssertEqual(recorder.events[2].properties, ["goals": "voice,launcher,chat"])
        XCTAssertEqual(recorder.events[4].properties["duration_seconds"], "12")
        XCTAssertEqual(recorder.events[4].properties["goals"], "voice,launcher,chat")
        XCTAssertEqual(recorder.events[4].properties["missing_permissions"], "0")
    }

    @MainActor
    func testAnalyticsReportsSkippedPermissionsAndAbandonmentOnce() {
        let recorder = AnalyticsEventRecorder()
        let viewModel = OnboardingViewModel(settingsStore: store, analyticsReporter: recorder, onComplete: {})
        viewModel.currentStep = .permissions
        viewModel.permissions = [.init(id: .microphone, state: .needsAttention, detail: "Missing")]

        viewModel.finishLater()
        viewModel.skipWithoutAnimation()

        XCTAssertEqual(recorder.events.map(\.name), ["onboarding_step_completed", "onboarding_completed"])
        XCTAssertEqual(recorder.events[0].properties, ["step": "permissions", "skipped": "true"])
        XCTAssertEqual(recorder.events[1].properties["missing_permissions"], "2")

        let abandoning = AnalyticsEventRecorder()
        let other = OnboardingViewModel(settingsStore: store, analyticsReporter: abandoning, onComplete: {})
        other.skipWithoutAnimation()
        other.skipWithoutAnimation()
        XCTAssertEqual(abandoning.events.map(\.name), ["onboarding_abandoned"])
        XCTAssertEqual(abandoning.events[0].properties, ["last_step": "welcome"])
    }

    // MARK: - Helpers

    @MainActor
    private func finish(_ viewModel: OnboardingViewModel) {
        viewModel.currentStep = .permissions
        viewModel.permissions = grantedPermissions()
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
