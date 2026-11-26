@testable import Typeflux
import XCTest

final class ClassicIntroPolicyTests: XCTestCase {
    func testFreshInstallIsNotEligible() {
        XCTAssertEqual(
            ClassicIntroPolicy.decide(onboardingCompletedBeforeLaunch: false, shownVersion: nil,
                                      isIneligible: false, needsOnboarding: true),
            .notEligible
        )
    }

    func testUpgradeFromOneZeroZeroShows() {
        XCTAssertEqual(
            ClassicIntroPolicy.decide(onboardingCompletedBeforeLaunch: true, shownVersion: nil,
                                      isIneligible: false, needsOnboarding: false),
            .show
        )
    }

    func testAlreadyShownNeverShowsAgain() {
        XCTAssertEqual(
            ClassicIntroPolicy.decide(onboardingCompletedBeforeLaunch: true, shownVersion: "1.0.1",
                                      isIneligible: false, needsOnboarding: false),
            .alreadyShown
        )
    }

    func testExistingUserWhoMustRepeatOnboardingWaitsForIt() {
        XCTAssertEqual(
            ClassicIntroPolicy.decide(onboardingCompletedBeforeLaunch: true, shownVersion: nil,
                                      isIneligible: false, needsOnboarding: true),
            .showAfterOnboarding
        )
    }

    func testRecordedFreshInstallStaysIneligibleAfterOnboardingCompletes() {
        XCTAssertEqual(
            ClassicIntroPolicy.decide(onboardingCompletedBeforeLaunch: true, shownVersion: nil,
                                      isIneligible: true, needsOnboarding: false),
            .notEligible
        )
    }
}

@MainActor
final class ClassicIntroCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClassicIntroCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeCoordinator(available: Bool = true, presented: @escaping () -> Void) -> ClassicIntroCoordinator {
        ClassicIntroCoordinator(
            store: ClassicIntroStore(defaults: defaults),
            currentVersion: "1.0.1",
            isClassicAvailable: { available },
            present: presented
        )
    }

    func testStoreReadsRawOnboardingFlag() {
        let store = ClassicIntroStore(defaults: defaults)
        XCTAssertFalse(store.onboardingCompleted)
        defaults.set(true, forKey: "onboarding.completed")
        XCTAssertTrue(store.onboardingCompleted)
    }

    func testFreshInstallNeverPresentsEvenOnLaterLaunches() async {
        var presentations = 0
        let first = makeCoordinator { presentations += 1 }
        XCTAssertEqual(first.launch(onboardingCompletedBeforeLaunch: false, needsOnboarding: true), .notEligible)
        first.onboardingDidFinish()
        await first.waitForEvaluation()
        XCTAssertTrue(defaults.bool(forKey: ClassicIntroStore.ineligibleKey))

        // Next launch: onboarding has completed in the meantime.
        let second = makeCoordinator { presentations += 1 }
        XCTAssertEqual(second.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: false), .notEligible)
        await second.waitForEvaluation()

        XCTAssertEqual(presentations, 0)
        XCTAssertNil(defaults.string(forKey: ClassicIntroStore.shownVersionKey))
    }

    func testUpgradePresentsOnceAndRecordsVersion() async {
        var presentations = 0
        let first = makeCoordinator { presentations += 1 }
        XCTAssertEqual(first.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: false), .show)
        await first.waitForEvaluation()

        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(first.hasPresented)
        XCTAssertEqual(defaults.string(forKey: ClassicIntroStore.shownVersionKey), "1.0.1")

        let relaunch = makeCoordinator { presentations += 1 }
        XCTAssertEqual(relaunch.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: false), .alreadyShown)
        await relaunch.waitForEvaluation()
        XCTAssertEqual(presentations, 1)
    }

    func testOnboardingRunsFirstThenIntroAppears() async {
        var presentations = 0
        let coordinator = makeCoordinator { presentations += 1 }
        XCTAssertEqual(coordinator.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: true),
                       .showAfterOnboarding)
        await coordinator.waitForEvaluation()
        XCTAssertEqual(presentations, 0)
        XCTAssertNil(defaults.string(forKey: ClassicIntroStore.shownVersionKey))

        coordinator.onboardingDidFinish()
        await coordinator.waitForEvaluation()
        XCTAssertEqual(presentations, 1)

        // Reopening onboarding later in the session does not present again.
        coordinator.onboardingDidFinish()
        await coordinator.waitForEvaluation()
        XCTAssertEqual(presentations, 1)
    }

    func testUnavailableClassicDefersWithoutRecording() async {
        var presentations = 0
        let coordinator = makeCoordinator(available: false) { presentations += 1 }
        XCTAssertEqual(coordinator.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: false), .show)
        await coordinator.waitForEvaluation()

        XCTAssertEqual(presentations, 0)
        XCTAssertNil(defaults.string(forKey: ClassicIntroStore.shownVersionKey))
        XCTAssertFalse(defaults.bool(forKey: ClassicIntroStore.ineligibleKey))

        let nextLaunch = makeCoordinator(available: true) { presentations += 1 }
        XCTAssertEqual(nextLaunch.launch(onboardingCompletedBeforeLaunch: true, needsOnboarding: false), .show)
        await nextLaunch.waitForEvaluation()
        XCTAssertEqual(presentations, 1)
    }
}
