@testable import Typeflux
import XCTest

final class OnboardingViewModelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        store = nil
        super.tearDown()
    }

    @MainActor
    func testVisibleStepsDoNotIncludeWelcomeStep() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.visibleSteps, [.language, .account, .stt, .llm, .permissions, .shortcuts])
        XCTAssertEqual(viewModel.currentStep, .language)
    }

    @MainActor
    func testAdvanceFromLanguageMovesToAccountStep() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.advance()

        XCTAssertEqual(viewModel.currentStep, .account)
    }

    @MainActor
    func testAdvanceFromAccountWithoutLoginMovesToSTT() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.currentStep = .account

        viewModel.advance()

        XCTAssertEqual(viewModel.currentStep, .stt)
    }

    @MainActor
    func testUsingCloudAccountSkipsModelConfigurationSteps() {
        let authState = makeLoggedInAuthState()
        let viewModel = OnboardingViewModel(settingsStore: store, authState: authState, onComplete: {})
        viewModel.currentStep = .account

        viewModel.useCloudAccountModelsAndContinue()

        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertEqual(viewModel.visibleSteps, [.language, .account, .permissions, .shortcuts])
        XCTAssertEqual(store.sttProvider, .typefluxOfficial)
        XCTAssertEqual(store.llmProvider, .openAICompatible)
        XCTAssertEqual(store.llmRemoteProvider, .typefluxCloud)
    }

    @MainActor
    func testMultimodalSTTSkipsLLMStep() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.currentStep = .stt
        viewModel.sttProvider = .multimodalLLM

        viewModel.advance()
        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertFalse(viewModel.visibleSteps.contains(.llm))

        viewModel.goBack()
        XCTAssertEqual(viewModel.currentStep, .stt)
    }

    @MainActor
    func testAdvanceFromPermissionsShowsAlertWhenRequiredPermissionsAreMissing() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.currentStep = .permissions
        viewModel.permissions = [
            PrivacyGuard.PermissionSnapshot(
                id: .microphone,
                state: .needsAttention,
                detail: "Microphone missing",
            ),
            PrivacyGuard.PermissionSnapshot(
                id: .speechRecognition,
                state: .granted,
                detail: "Speech granted",
            ),
            PrivacyGuard.PermissionSnapshot(
                id: .accessibility,
                state: .granted,
                detail: "Accessibility granted",
            ),
        ]

        viewModel.advance()

        XCTAssertEqual(viewModel.currentStep, .permissions)
        XCTAssertTrue(viewModel.showIncompletePermissionsAlert)
    }

    @MainActor
    func testAdvanceFromPermissionsContinuesWhenRequiredPermissionsAreGranted() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.currentStep = .permissions
        viewModel.permissions = [
            PrivacyGuard.PermissionSnapshot(
                id: .microphone,
                state: .granted,
                detail: "Microphone granted",
            ),
            PrivacyGuard.PermissionSnapshot(
                id: .speechRecognition,
                state: .needsAttention,
                detail: "Speech missing",
            ),
            PrivacyGuard.PermissionSnapshot(
                id: .accessibility,
                state: .granted,
                detail: "Accessibility granted",
            ),
        ]

        viewModel.advance()

        XCTAssertEqual(viewModel.currentStep, .shortcuts)
        XCTAssertFalse(viewModel.showIncompletePermissionsAlert)
    }

    @MainActor
    func testInitialSTTProviderFallsBackWhenTypefluxCloudIsHiddenInOnboarding() {
        store.sttProvider = .typefluxOfficial

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.sttProvider, .localModel)
    }

    @MainActor
    func testInitialLLMProviderFallsBackWhenTypefluxCloudIsHiddenInOnboarding() {
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .typefluxCloud

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.llmProvider, .openAICompatible)
        XCTAssertEqual(viewModel.llmRemoteProvider, .custom)
    }

    @MainActor
    func testNewUserDefaultsToSenseVoiceAndOpenAI() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        XCTAssertEqual(viewModel.sttProvider, .localModel)
        XCTAssertEqual(viewModel.localSTTModel, .senseVoiceSmall)
        XCTAssertEqual(viewModel.llmProvider, .openAICompatible)
        XCTAssertEqual(viewModel.llmRemoteProvider, .openAI)
    }

    // MARK: - Default persona selection on completion

    @MainActor
    func testCompletingOnboardingWithCloudLoginSelectsTypefluxPersona() {
        let authState = makeLoggedInAuthState()
        let viewModel = OnboardingViewModel(settingsStore: store, authState: authState, onComplete: {})

        viewModel.currentStep = .account
        viewModel.useCloudAccountModelsAndContinue()
        completeOnboarding(viewModel)

        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        XCTAssertEqual(store.activePersona?.name, "Typeflux")
    }

    @MainActor
    func testCompletingOnboardingWithCustomLLMSelectsTypefluxPersona() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        viewModel.currentStep = .llm
        viewModel.llmProvider = .openAICompatible
        viewModel.llmRemoteProvider = .custom
        viewModel.llmBaseURL = "https://example.com/v1"
        viewModel.llmModel = "my-model"
        completeOnboarding(viewModel)

        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    @MainActor
    func testCompletingOnboardingWithoutLLMLeavesPersonaDisabled() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        // Go through all steps without configuring LLM (default openAI, no API key).
        completeOnboarding(viewModel)

        XCTAssertFalse(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, "")
        XCTAssertNil(store.activePersona)
    }

    @MainActor
    func testCompletingOnboardingDoesNotOverwriteExplicitPersonaChoice() {
        // User pre-selected the "English Translator" persona before completing onboarding.
        let translatorID = UUID(uuidString: "2A7A4A74-A8AC-4F3C-9FB1-5A433EDFA002")!
        store.applyPersonaSelection(translatorID)

        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})
        viewModel.currentStep = .llm
        viewModel.llmProvider = .openAICompatible
        viewModel.llmRemoteProvider = .custom
        viewModel.llmBaseURL = "https://example.com/v1"
        viewModel.llmModel = "my-model"
        completeOnboarding(viewModel)

        XCTAssertEqual(store.activePersonaID, translatorID.uuidString)
    }

    @MainActor
    func testSkipWithoutAnimationAppliesDefaultPersonaWhenLLMConfigured() {
        let viewModel = OnboardingViewModel(settingsStore: store, onComplete: {})

        // Simulate a pre-configured LLM before the user closes the onboarding window.
        store.llmProvider = .openAICompatible
        store.llmRemoteProvider = .custom
        store.setLLMBaseURL("https://example.com/v1", for: .custom)
        store.setLLMModel("my-model", for: .custom)

        viewModel.skipWithoutAnimation()

        XCTAssertTrue(store.isOnboardingCompleted)
        XCTAssertTrue(store.personaRewriteEnabled)
        XCTAssertEqual(store.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
    }

    @MainActor
    private func completeOnboarding(_ viewModel: OnboardingViewModel) {
        // Advance until onboarding marks itself complete. `advance()` no-ops past the last step,
        // so bound the loop to avoid infinite iteration if `isOnboardingCompleted` is never set.
        var guardCounter = 0
        while !store.isOnboardingCompleted, guardCounter < 20 {
            // The permissions step blocks advance() unless required permissions are granted.
            // Stub them as granted so the loop can progress.
            if viewModel.currentStep == .permissions {
                viewModel.permissions = PrivacyGuard.requiredPermissionIDs(settingsStore: store).map { id in
                    PrivacyGuard.PermissionSnapshot(id: id, state: .granted, detail: "Granted in test")
                }
            }
            viewModel.advance()
            guardCounter += 1
        }
        XCTAssertTrue(store.isOnboardingCompleted, "Onboarding failed to complete within bounded iterations")
    }

    @MainActor
    private func makeLoggedInAuthState() -> AuthState {
        let storedToken = (
            token: "token",
            expiresAt: Int(Date().timeIntervalSince1970) + 3600
        )
        let storedProfile = UserProfile(
            id: "user_123",
            email: "test@example.com",
            name: "Test User",
            status: 1,
            provider: "email",
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        let authState = AuthState(
            loadStoredToken: { storedToken },
            loadStoredUserProfile: { storedProfile },
            saveStoredToken: { _, _ in },
            saveStoredUserProfile: { _ in },
            clearStoredSession: {},
            fetchProfile: { _ in storedProfile }
        )
        return authState
    }

    @MainActor
    func testKeyboardSystemSettingsURLPointsToKeyboardPane() {
        let url = OnboardingViewModel.keyboardSystemSettingsURL
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertTrue(
            url.absoluteString.contains("Keyboard"),
            "URL should target the Keyboard settings pane, got: \(url.absoluteString)",
        )
    }

    @MainActor
    func testIsGlobeKeyReadyReflectsInitialReaderState() {
        let readyReader = StubGlobeKeyPreferenceReader(usage: .doNothing)
        let notReadyReader = StubGlobeKeyPreferenceReader(usage: .showEmojiAndSymbols)

        let readyVM = OnboardingViewModel(
            settingsStore: store,
            globeKeyReader: readyReader,
            onComplete: {},
        )
        let notReadyVM = OnboardingViewModel(
            settingsStore: store,
            globeKeyReader: notReadyReader,
            onComplete: {},
        )

        XCTAssertTrue(readyVM.isGlobeKeyReady)
        XCTAssertFalse(notReadyVM.isGlobeKeyReady)
    }

    @MainActor
    func testRefreshGlobeKeyStatePicksUpChanges() {
        let reader = StubGlobeKeyPreferenceReader(usage: .changeInputSource)
        let viewModel = OnboardingViewModel(
            settingsStore: store,
            globeKeyReader: reader,
            onComplete: {},
        )
        XCTAssertFalse(viewModel.isGlobeKeyReady)

        reader.usage = .doNothing
        viewModel.refreshGlobeKeyState()
        XCTAssertTrue(viewModel.isGlobeKeyReady)

        reader.usage = .startDictation
        viewModel.refreshGlobeKeyState()
        XCTAssertFalse(viewModel.isGlobeKeyReady)
    }
}

private final class StubGlobeKeyPreferenceReader: GlobeKeyPreferenceReading {
    var usage: GlobeKeyUsage

    init(usage: GlobeKeyUsage) {
        self.usage = usage
    }

    func currentUsage() -> GlobeKeyUsage {
        usage
    }
}
