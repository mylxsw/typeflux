import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class RingHotkeyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RingHotkeyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRingShortcutIsRegisteredOnlyWhileTheRingCanOpen() {
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        XCTAssertNotNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])

        var configuration = store.ringConfiguration
        configuration.enabled = false
        store.ringConfiguration = configuration
        XCTAssertNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
        XCTAssertNotNil(store.hotkeyAssignments[.action(.ring)], "the keys stay reserved for the ring")

        configuration.enabled = true
        configuration.actions = []
        store.ringConfiguration = configuration
        XCTAssertNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
    }

    func testShortcutsPageListsTheRing() {
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        XCTAssertEqual(HotkeySettingsPresentation.group(of: .ring), .launcher)
        XCTAssertEqual(HotkeySettingsPresentation.icon(of: .ring), RingSettingsPresentation.symbol)
        let rows = HotkeySettingsPresentation.rows(settingsStore: store, keywords: [])
        let row = rows.first { $0.target == .action(.ring) }
        XCTAssertEqual(row?.title, L("hotkeys.action.ring.title"))
        XCTAssertEqual(row?.binding?.signature, RingConfiguration.defaultHotkey.signature)
        XCTAssertFalse(L("hotkeys.action.ring.subtitle").hasPrefix("hotkeys."))
    }

    func testDefaultShortcutPassesTheConflictCheck() {
        let result = HotkeyConflictChecker.check(RingConfiguration.defaultHotkey, for: .action(.ring), among: [:])
        XCTAssertTrue(result.canSave)
    }

    func testPoolReportsPressAndReleaseOfRegisteredShortcuts() async throws {
        let pool = SystemHotkeyPool(name: "RingHotkeyTests")
        defer { pool.unregisterAll() }
        // ⌃⌥⇧F19: unlikely to be taken by anything on the test machine.
        let binding = HotkeyBinding(keyCode: 80, modifierFlags: UInt(NSEvent.ModifierFlags([.control, .option, .shift])
                .rawValue))
        pool.register([.action(.ring): binding])
        let id = try XCTUnwrap(pool.registrationID(of: .action(.ring)))
        var pressed: [HotkeyTarget] = []
        var released: [HotkeyTarget] = []
        pool.onPressed = { pressed.append($0) }
        pool.onReleased = { released.append($0) }

        XCTAssertTrue(pool.handlePressed(id: id))
        XCTAssertTrue(pool.handleReleased(id: id))
        XCTAssertFalse(pool.handleReleased(id: id + 100))
        XCTAssertNil(pool.registrationID(of: .action(.openNotes)))
        for _ in 0..<50 where released.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pressed, [.action(.ring)])
        XCTAssertEqual(released, [.action(.ring)])
    }
}
