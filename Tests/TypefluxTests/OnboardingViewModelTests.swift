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
}
