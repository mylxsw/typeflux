import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class RingConfigurationTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RingConfigurationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsOfferSixFeaturesFrostedAndOn() {
        let configuration = RingConfiguration()
        XCTAssertTrue(configuration.enabled)
        XCTAssertTrue(configuration.isUsable)
        XCTAssertEqual(configuration.style, .frosted)
        XCTAssertEqual(configuration.centerTitle, "Typeflux")
        XCTAssertEqual(configuration.actions.map(\.kind), [
            .feature(.dictation), .feature(.ask), .feature(.translate), .feature(.screenshot),
            .feature(.screenshotText), .feature(.clipboard)
        ])
        XCTAssertEqual(configuration.actions.map(\.symbol), configuration.actions.map {
            if case let .feature(feature) = $0.kind { return feature.symbol }
            return ""
        })
        XCTAssertEqual(Set(configuration.actions.map(\.id)).count, 6)
        XCTAssertEqual(configuration.actions.map(\.id), RingConfiguration().actions.map(\.id),
                       "defaults keep their ids")
    }

    func testUsableOnlyWhenOnAndNotEmpty() {
        var configuration = RingConfiguration()
        configuration.enabled = false
        XCTAssertFalse(configuration.isUsable)
        configuration.enabled = true
        configuration.actions = []
        XCTAssertFalse(configuration.isUsable)
        XCTAssertTrue(configuration.canAddAction)
        configuration.actions = Array(repeating: RingAction.feature(.notes), count: RingConfiguration.maxActions)
        XCTAssertFalse(configuration.canAddAction)
    }

    func testEveryKindRoundTrips() throws {
        let binding = HotkeyBinding(keyCode: 21, modifierFlags: Self.flags([.command, .shift]))
        let actions = [
            RingAction.feature(.persona),
            RingAction(kind: .keyword(keyword: "rw", pluginID: "custom.rw"), title: "Polish", symbol: "wand.and.stars"),
            RingAction(kind: .app(bundleIdentifier: "com.apple.Safari", name: "Safari"), title: "Safari",
                       symbol: "app"),
            RingAction(kind: .keys(binding), title: "Screenshot", symbol: "keyboard"),
            RingAction(kind: .system(.darkMode), title: "Dark", symbol: "moon"),
            RingAction(kind: .shortcut(name: "Pomodoro"), title: "Pomodoro", symbol: "timer"),
            RingAction(kind: .url("https://typeflux.app"), title: "Typeflux", symbol: "link"),
            RingAction(kind: .folder(path: "~/Downloads"), title: "Downloads", symbol: "folder")
        ]
        let configuration = RingConfiguration(enabled: false, actions: actions, style: .liquidGlass, centerTitle: "Go")
        let decoded = try JSONDecoder().decode(RingConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.actions.map(\.kind.type), RingActionType.allCases)
    }

    func testDecodingKeepsDefaultsSkipsUnknownActionsAndCapsTheCount() throws {
        let empty = try JSONDecoder().decode(RingConfiguration.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.enabled)
        XCTAssertEqual(empty.actions.map(\.kind), RingConfiguration.defaultActions().map(\.kind))
        let known = try XCTUnwrap(String(bytes: JSONEncoder().encode(RingAction.feature(.notes)), encoding: .utf8))
        let unknown = #"{"id":"\#(UUID().uuidString)","kind":{"teleport":{}},"title":"?","symbol":"x"}"#
        let actions = ([known, unknown] + Array(repeating: known, count: 9)).joined(separator: ",")
        let json = #"{"enabled":false,"style":"future","actions":[\#(actions)]}"#
        let decoded = try JSONDecoder().decode(RingConfiguration.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.style, .frosted)
        XCTAssertEqual(decoded.centerTitle, "Typeflux")
        XCTAssertEqual(decoded.actions.count, RingConfiguration.maxActions)
        XCTAssertTrue(decoded.actions.allSatisfy { $0.kind == .feature(.notes) })
    }

    func testStorePersistsAndNotifies() {
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.ringConfiguration.actions.count, 6)
        var ringChanges = 0
        var hotkeyChanges = 0
        let ring = NotificationCenter.default.addObserver(forName: .ringSettingsDidChange, object: store,
                                                          queue: nil) { _ in ringChanges += 1 }
        let hotkeys = NotificationCenter.default.addObserver(forName: .hotkeySettingsDidChange, object: store,
                                                             queue: nil) { _ in hotkeyChanges += 1 }
        defer {
            NotificationCenter.default.removeObserver(ring)
            NotificationCenter.default.removeObserver(hotkeys)
        }

        var configuration = store.ringConfiguration
        configuration.style = .classic
        store.ringConfiguration = configuration
        XCTAssertEqual([ringChanges, hotkeyChanges], [1, 0])

        configuration.enabled = false
        store.ringConfiguration = configuration
        XCTAssertEqual([ringChanges, hotkeyChanges], [2, 1], "turning the ring off releases its shortcut")
        XCTAssertEqual(SettingsStore(defaults: defaults).ringConfiguration, configuration)
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        defaults.set(Data("not json".utf8), forKey: "ring.configuration.json")
        XCTAssertEqual(SettingsStore(defaults: defaults).ringConfiguration.actions.count, 6)
    }

    /// A store whose first-run seeding is undone, so a test controls what macOS reports.
    private func unseededStore() -> SettingsStore {
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(nil, for: .ring)
        defaults.removeObject(forKey: "ring.hotkeySeeded")
        return store
    }

    func testShortcutIsSeededOnceWhenFree() {
        let store = unseededStore()
        store.seedRingHotkeyIfNeeded(systemShortcuts: .none)
        XCTAssertEqual(store.actionHotkeys[.ring]?.signature, RingConfiguration.defaultHotkey.signature)

        store.setHotkey(nil, for: .ring)
        store.seedRingHotkeyIfNeeded(systemShortcuts: .none)
        XCTAssertNil(SettingsStore(defaults: defaults).actionHotkeys[.ring], "a removed shortcut stays removed")
    }

    func testShortcutIsNotSeededWhenMacOSUsesTheKeys() {
        let store = unseededStore()
        let inputSources = SystemSymbolicHotkeys(enabled: [.init(keyCode: 49, modifierFlags: 786_432)])
        store.seedRingHotkeyIfNeeded(systemShortcuts: inputSources)
        XCTAssertNil(store.actionHotkeys[.ring])
    }

    func testSymbolicHotkeysReadOnlyEnabledShortcuts() {
        let preferences: [String: Any] = [
            "61": ["enabled": NSNumber(value: true),
                   "value": ["parameters": [32, 49, 786_432].map(NSNumber.init(value:)), "type": "standard"]],
            "60": ["enabled": NSNumber(value: false),
                   "value": ["parameters": [32, 49, 262_144].map(NSNumber.init(value:)), "type": "standard"]],
            "64": ["enabled": NSNumber(value: true),
                   "value": ["parameters": [65535, 65535, 0].map(NSNumber.init(value:)), "type": "standard"]],
            "bad": "not a dictionary"
        ]
        let shortcuts = SystemSymbolicHotkeys(preferences: preferences)
        XCTAssertEqual(shortcuts.enabled, [.init(keyCode: 49, modifierFlags: 786_432)])
        XCTAssertTrue(shortcuts.contains(RingConfiguration.defaultHotkey))
        XCTAssertFalse(shortcuts.contains(HotkeyBinding(keyCode: 49, modifierFlags: Self.flags(.control))))
        XCTAssertFalse(SystemSymbolicHotkeys.none.contains(RingConfiguration.defaultHotkey))
        _ = SystemSymbolicHotkeys.current
    }

    func testShortcutIsNotSeededWhenTheKeysAreTaken() throws {
        let taken = try JSONEncoder().encode(["openNotes": RingConfiguration.defaultHotkey])
        defaults.set(taken, forKey: "hotkey.actions.json")
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.actionHotkeys[.ring])
        XCTAssertEqual(store.actionHotkeys[.openNotes]?.signature, RingConfiguration.defaultHotkey.signature)
    }

    func testShortcutIsNotReplacedWhenAlreadySet() throws {
        let own = HotkeyBinding(keyCode: 15, modifierFlags: Self.flags([.control, .option]))
        defaults.set(try JSONEncoder().encode(["ring": own]), forKey: "hotkey.actions.json")
        XCTAssertEqual(SettingsStore(defaults: defaults).actionHotkeys[.ring]?.signature, own.signature)
    }

    static func flags(_ flags: NSEvent.ModifierFlags) -> UInt {
        UInt(flags.rawValue)
    }
}
