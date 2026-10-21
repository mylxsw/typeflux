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
        store.setHotkey(nil, for: .ring)
        XCTAssertNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
        XCTAssertNil(store.hotkeyAssignments[.action(.ring)])

        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        XCTAssertNotNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
        configuration.actions = []
        store.ringConfiguration = configuration
        XCTAssertNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
    }

    func testLegacyDisabledFlagDoesNotBlockAnAssignedShortcut() throws {
        defaults.set(Data(#"{"enabled":false}"#.utf8), forKey: "ring.configuration.json")
        let store = SettingsStore(defaults: defaults)
        store.setHotkey(RingConfiguration.defaultHotkey, for: .ring)
        XCTAssertNotNil(EventTapHotkeyService.shortcutBindings(in: store)[.action(.ring)])
        let encoded = try JSONEncoder().encode(store.ringConfiguration)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["enabled"], "the retired flag is no longer persisted")
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

    func testModifierBindingSavesPersistsAndRoutesThroughEventService() async {
        let store = SettingsStore(defaults: defaults)
        let model = HotkeySettingsModel(settingsStore: store, workflows: AskWorkflowStore(settings: store, root: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)))
        XCTAssertNil(model.setHotkey(.rightOptionActivation, for: .ring))
        XCTAssertEqual(SettingsStore(defaults: defaults).actionHotkeys[.ring]?.signature,
                       HotkeyBinding.rightOptionActivation.signature)
        let service = EventTapHotkeyService(settingsStore: store)
        service.refreshBindings()
        var events: [String] = []
        service.onShortcutRequested = { if $0 == .action(.ring) { events.append("press") } }
        service.onShortcutReleased = { if $0 == .action(.ring) { events.append("release") } }
        service.onShortcutCancelled = { if $0 == .action(.ring) { events.append("cancel") } }
        let flags = HotkeyBinding.rightOptionActivation.modifierFlags
        func send(_ type: HotkeyPhysicalEventType, _ key: Int, _ value: UInt) -> Bool {
            service.processPhysicalEvent(eventType: type, keyCode: key, modifierFlags: value,
                                         isRepeat: false, canConsume: true, timestamp: 1)
        }
        XCTAssertTrue(send(.flagsChanged, 61, flags))
        XCTAssertTrue(send(.flagsChanged, 61, 0))
        XCTAssertTrue(send(.flagsChanged, 61, flags))
        XCTAssertFalse(send(.keyDown, 8, flags), "the user's normal shortcut must pass through")
        _ = send(.keyUp, 8, flags)
        XCTAssertTrue(send(.flagsChanged, 61, 0))
        _ = send(.flagsChanged, 61, flags)
        store.setHotkey(nil, for: .ring)
        service.refreshBindings()
        XCTAssertFalse(send(.flagsChanged, 61, 0))
        XCTAssertFalse(send(.flagsChanged, 61, flags))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(events, ["press", "release", "press", "cancel", "press", "cancel"])
        service.stop()
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
