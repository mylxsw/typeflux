@testable import Typeflux
import XCTest

final class OnboardingGoalTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingGoalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testEveryGoalHasCopySymbolAndDuration() {
        for goal in OnboardingGoal.allCases {
            XCTAssertNotEqual(goal.title, "onboarding.goal.\(goal.rawValue).title")
            XCTAssertNotEqual(goal.detail, "onboarding.goal.\(goal.rawValue).detail")
            XCTAssertFalse(goal.symbol.isEmpty)
            XCTAssertGreaterThan(goal.estimatedMinutes, 0)
            XCTAssertEqual(goal.id, goal.rawValue)
        }
    }

    func testPermissionsPerGoal() {
        XCTAssertEqual(OnboardingGoal.voice.requiredPermissions, [.microphone, .accessibility])
        XCTAssertEqual(OnboardingGoal.launcher.requiredPermissions, [.accessibility])
        XCTAssertEqual(OnboardingGoal.ring.requiredPermissions, [.accessibility])
        XCTAssertEqual(OnboardingGoal.chat.requiredPermissions, [.microphone])
        XCTAssertTrue(OnboardingGoal.tools.requiredPermissions.isEmpty,
                      "Screen recording and camera are asked for when first used")
    }

    @MainActor
    func testRequiredPermissionsAreOrderedAndDeduplicated() {
        store.useAppleSpeechFallback = false
        XCTAssertEqual(OnboardingGoal.requiredPermissionIDs(for: [.chat, .ring], settingsStore: store),
                       [.microphone, .accessibility])
        XCTAssertTrue(OnboardingGoal.requiredPermissionIDs(for: [], settingsStore: store).isEmpty)
    }

    @MainActor
    func testSpeechRecognitionIsAddedOnlyForVoiceWithAppleSpeech() {
        store.useAppleSpeechFallback = true
        XCTAssertEqual(OnboardingGoal.requiredPermissionIDs(for: [.voice], settingsStore: store),
                       [.microphone, .speechRecognition, .accessibility])
        XCTAssertEqual(OnboardingGoal.requiredPermissionIDs(for: [.chat], settingsStore: store), [.microphone])
    }

    func testOrderedFollowsDeclarationOrder() {
        XCTAssertEqual(OnboardingGoal.ordered([.chat, .voice, .ring]), [.voice, .ring, .chat])
    }

    func testStoredGoalsRoundTripAndClear() {
        XCTAssertNil(store.onboardingGoals)

        store.onboardingGoals = [.chat, .tools]
        XCTAssertEqual(store.onboardingGoals, [.tools, .chat])
        XCTAssertEqual(defaults.array(forKey: "onboarding.goals") as? [String], ["tools", "chat"])

        defaults.set(["voice", "unknown"], forKey: "onboarding.goals")
        XCTAssertEqual(store.onboardingGoals, [.voice], "Unknown goals from newer versions are skipped")

        store.onboardingGoals = nil
        XCTAssertNil(store.onboardingGoals)
    }
}
