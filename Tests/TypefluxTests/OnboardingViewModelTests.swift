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
}
