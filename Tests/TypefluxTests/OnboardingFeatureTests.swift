import AppKit
@testable import Typeflux
import XCTest

final class OnboardingFeatureTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingFeatureTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    func testPermissionsPerFeature() {
        XCTAssertEqual(OnboardingFeature.voice.requiredPermissions, [.microphone, .accessibility])
        XCTAssertEqual(OnboardingFeature.launcher.requiredPermissions, [.accessibility])
        XCTAssertEqual(OnboardingFeature.ring.requiredPermissions, [.accessibility])
        XCTAssertEqual(OnboardingFeature.chat.requiredPermissions, [.microphone])
        XCTAssertTrue(OnboardingFeature.tools.requiredPermissions.isEmpty,
                      "Screen recording and camera are asked for when first used")
    }

    @MainActor
    func testRequiredPermissionsAreOrderedAndAddSpeechOnlyForAppleSpeech() {
        store.useAppleSpeechFallback = false
        XCTAssertEqual(OnboardingFeature.requiredPermissionIDs(settingsStore: store), [.microphone, .accessibility])

        store.useAppleSpeechFallback = true
        XCTAssertEqual(OnboardingFeature.requiredPermissionIDs(settingsStore: store),
                       [.microphone, .speechRecognition, .accessibility])
    }

}
