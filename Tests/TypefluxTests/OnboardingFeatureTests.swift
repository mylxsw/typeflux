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

    func testEveryFeatureHasCopyAndSymbol() {
        for feature in OnboardingFeature.allCases {
            XCTAssertNotEqual(feature.title, "onboarding.feature.\(feature.rawValue).title")
            XCTAssertNotEqual(feature.caption, "onboarding.feature.\(feature.rawValue).caption")
            XCTAssertFalse(feature.symbol.isEmpty)
            XCTAssertEqual(feature.id, feature.rawValue)
        }
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

    func testPermissionChipsListTheFeaturesThatNeedIt() {
        XCTAssertEqual(OnboardingFeature.features(using: .accessibility), [.voice, .launcher, .ring])
        XCTAssertEqual(OnboardingFeature.features(using: .microphone), [.voice, .chat])
        XCTAssertEqual(OnboardingFeature.features(using: .speechRecognition), [.voice])
    }

    @MainActor
    func testDefaultShortcutsTeachEveryFeature() {
        store.setHotkey(nil, for: .ring) // Seeded only when macOS leaves ⌃⌥Space free
        let launcher = HotkeyFormat.components(.defaultAsk)
        let screenshot = HotkeyFormat.components(.defaultScreenshot)
        let fn = HotkeyFormat.components(.defaultActivation)

        XCTAssertEqual(keys(.voice), [fn, fn])
        XCTAssertEqual(keys(.launcher), [launcher, HotkeyFormat.components(.defaultHistory), screenshot])
        XCTAssertEqual(keys(.tools), [launcher + ["fy"], screenshot + ["⏺"], launcher],
                       "Without a translate key, translation is taught through the launcher")
        XCTAssertEqual(keys(.ring), [[]], "No ring key yet: the guide points to Settings")
        XCTAssertEqual(keys(.chat), [launcher + ["↩"]])

        for feature in OnboardingFeature.allCases {
            for shortcut in feature.shortcuts(settingsStore: store) {
                XCTAssertFalse(shortcut.title.hasPrefix("onboarding."), shortcut.id)
            }
        }
    }

    @MainActor
    func testShortcutsFollowTheUsersKeys() {
        let translate = HotkeyBinding(keyCode: 17, modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue))
        let chat = HotkeyBinding(keyCode: 8, modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue))
        store.activationHotkey = .rightCommandActivation
        store.setHotkey(translate, for: .translate)
        store.setHotkey(chat, for: .openChat)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)

        XCTAssertEqual(keys(.voice).first, HotkeyFormat.components(.rightCommandActivation))
        XCTAssertEqual(keys(.tools).first, HotkeyFormat.components(translate))
        XCTAssertEqual(keys(.ring), [HotkeyFormat.components(RingConfiguration.defaultHotkey)])
        XCTAssertEqual(store.actionHotkeys.count, 3)
        XCTAssertEqual(OnboardingFeature.chat.shortcuts(settingsStore: store).map(\.id), ["chat.ask", "chat.window"])
        XCTAssertEqual(keys(.chat).last, HotkeyFormat.components(chat))
    }

    @MainActor
    func testUnsetLauncherLeavesStepsReachedThroughItEmpty() {
        store.askHotkey = nil
        store.setHotkey(nil, for: .openChat)

        XCTAssertEqual(keys(.launcher).first, [])
        XCTAssertEqual(keys(.tools), [[], HotkeyFormat.components(.defaultScreenshot) + ["⏺"], []])
        XCTAssertEqual(keys(.chat), [[]])
    }

    @MainActor
    private func keys(_ feature: OnboardingFeature) -> [[String]] {
        feature.shortcuts(settingsStore: store).map(\.keys)
    }
}
