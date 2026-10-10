import AppKit
@testable import Typeflux
import XCTest

final class ScreenshotHotkeyTests: XCTestCase {
    private let activation = HotkeyBinding.defaultActivation
    private let ask = HotkeyBinding.defaultAsk
    private let screenshot = HotkeyBinding.defaultScreenshot

    func testDefaultIsOptionCommandA() {
        XCTAssertEqual(screenshot.keyCode, 0)
        XCTAssertEqual(NSEvent.ModifierFlags(rawValue: screenshot.modifierFlags), [.command, .option])
        XCTAssertEqual(HotkeyFormat.display(screenshot), "⌥ ⌘ A")
        for other in [HotkeyBinding.defaultActivation, .defaultAsk, .defaultPersona, .defaultHistory,
                      .defaultAuxiliary] {
            XCTAssertFalse(other.conflicts(with: screenshot), "\(HotkeyFormat.display(other))")
        }
    }

    func testKeyDownRequestsAScreenshotAndIsConsumed() {
        var arbiter = HotkeyGestureArbiter()

        XCTAssertTrue(arbiter.shouldConsume(eventType: .keyDown, keyCode: screenshot.keyCode,
                                            modifierFlags: screenshot.modifierFlags, activationHotkey: activation,
                                            askHotkey: ask, personaHotkey: nil, screenshotHotkey: screenshot))
        let events = arbiter.handleKeyDown(keyCode: screenshot.keyCode, modifierFlags: screenshot.modifierFlags,
                                           isRepeat: false, activationHotkey: activation, askHotkey: ask,
                                           personaHotkey: nil, screenshotHotkey: screenshot)
        XCTAssertEqual(events, [.screenshotRequested])
        XCTAssertEqual(arbiter.phase, .idle)
    }

    func testWithoutABindingNothingHappens() {
        var arbiter = HotkeyGestureArbiter()

        XCTAssertFalse(arbiter.shouldConsume(eventType: .keyDown, keyCode: screenshot.keyCode,
                                             modifierFlags: screenshot.modifierFlags, activationHotkey: activation,
                                             askHotkey: ask, personaHotkey: nil))
        XCTAssertEqual(arbiter.handleKeyDown(keyCode: screenshot.keyCode, modifierFlags: screenshot.modifierFlags,
                                             isRepeat: false, activationHotkey: activation, askHotkey: ask,
                                             personaHotkey: nil), [])
    }

    func testRepeatsAndBusyPhasesAreIgnored() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertEqual(arbiter.handleKeyDown(keyCode: screenshot.keyCode, modifierFlags: screenshot.modifierFlags,
                                             isRepeat: true, activationHotkey: activation, askHotkey: ask,
                                             personaHotkey: nil, screenshotHotkey: screenshot), [])

        // While Ask is held, the screenshot shortcut does nothing.
        let askKey = HotkeyBinding(keyCode: 49, modifierFlags: UInt(NSEvent.ModifierFlags.control.rawValue))
        _ = arbiter.handleKeyDown(keyCode: askKey.keyCode, modifierFlags: askKey.modifierFlags, isRepeat: false,
                                  activationHotkey: activation, askHotkey: askKey, personaHotkey: nil)
        XCTAssertEqual(arbiter.phase, .active(.ask))
        XCTAssertEqual(arbiter.handleKeyDown(keyCode: screenshot.keyCode, modifierFlags: screenshot.modifierFlags,
                                             isRepeat: false, activationHotkey: activation, askHotkey: askKey,
                                             personaHotkey: nil, screenshotHotkey: screenshot), [])
    }

    func testModifierOnlyScreenshotWinsOverAPendingActivation() {
        var arbiter = HotkeyGestureArbiter()
        let rightOption = HotkeyBinding.rightOptionActivation

        XCTAssertTrue(arbiter.shouldConsume(eventType: .flagsChanged, keyCode: rightOption.keyCode,
                                            modifierFlags: rightOption.modifierFlags,
                                            activationHotkey: nil, askHotkey: nil, personaHotkey: nil,
                                            screenshotHotkey: rightOption))
        XCTAssertEqual(arbiter.handleFlagsChanged(keyCode: rightOption.keyCode,
                                                  modifierFlags: rightOption.modifierFlags,
                                                  activationHotkey: nil, askHotkey: nil,
                                                  screenshotHotkey: rightOption),
                       [.screenshotRequested])

        // A Fn activation that shares nothing with it begins at once and is not deferred.
        var other = HotkeyGestureArbiter()
        XCTAssertEqual(other.handleFlagsChanged(keyCode: activation.keyCode, modifierFlags: activation.modifierFlags,
                                                activationHotkey: activation, askHotkey: nil,
                                                screenshotHotkey: screenshot), [.begin(.activation)])
        XCTAssertFalse(other.hasPendingModifierActivation)
    }

    func testActivationSharingTheScreenshotModifierWaitsAndIsCancelled() {
        var arbiter = HotkeyGestureArbiter()
        let commandActivation = HotkeyBinding.rightCommandActivation
        let commandScreenshot = HotkeyBinding(keyCode: 0, modifierFlags: commandActivation.modifierFlags)

        XCTAssertEqual(arbiter.handleFlagsChanged(keyCode: commandActivation.keyCode,
                                                  modifierFlags: commandActivation.modifierFlags,
                                                  activationHotkey: commandActivation, askHotkey: nil,
                                                  screenshotHotkey: commandScreenshot), [.begin(.activation)])
        XCTAssertTrue(arbiter.hasPendingModifierActivation)

        XCTAssertEqual(arbiter.handleKeyDown(keyCode: 0, modifierFlags: commandScreenshot.modifierFlags,
                                             isRepeat: false, activationHotkey: commandActivation, askHotkey: nil,
                                             personaHotkey: nil, screenshotHotkey: commandScreenshot),
                       [.cancel(.activation), .screenshotRequested])
        XCTAssertEqual(arbiter.phase, .idle)
    }

    // MARK: Settings

    private func makeStore() throws -> SettingsStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ScreenshotHotkeyTests.\(UUID().uuidString)"))
        return SettingsStore(defaults: defaults)
    }

    func testStoreDefaultsUnsetsAndPersists() throws {
        let store = try makeStore()
        XCTAssertEqual(store.screenshotHotkey, .defaultScreenshot)

        let posted = expectation(forNotification: .hotkeySettingsDidChange, object: store)
        store.screenshotHotkey = nil
        wait(for: [posted], timeout: 1)
        XCTAssertNil(store.screenshotHotkey)
        XCTAssertEqual(store.screenshotHotkeyJSON, "__unset__")

        let custom = HotkeyBinding(keyCode: 1, modifierFlags: UInt(NSEvent.ModifierFlags.control.rawValue))
        store.screenshotHotkey = custom
        XCTAssertEqual(store.screenshotHotkey?.signature, custom.signature)
        XCTAssertNotNil(store.defaults.string(forKey: "hotkey.screenshot.json"))

        store.screenshotHotkeyJSON = "not json"
        XCTAssertEqual(store.screenshotHotkey, .defaultScreenshot)
    }

    func testAuxiliaryFallbackStepsAsideForTheScreenshotShortcut() throws {
        let store = try makeStore()
        store.screenshotHotkey = .defaultAuxiliary
        XCTAssertNil(store.auxiliaryHotkey)
    }

    func testSaveDirectoryDefaultsToTheDesktop() throws {
        let store = try makeStore()
        XCTAssertEqual(store.screenshotSaveDirectory, SettingsStore.defaultScreenshotSaveDirectory)
        XCTAssertEqual(SettingsStore.defaultScreenshotSaveDirectory.lastPathComponent, "Desktop")

        let folder = URL(fileURLWithPath: "/tmp/Shots", isDirectory: true)
        store.screenshotSaveDirectory = folder
        XCTAssertEqual(store.screenshotSaveDirectory.path, "/tmp/Shots")

        // Choosing the Desktop again stores nothing, so it follows the Desktop if it moves.
        store.screenshotSaveDirectory = SettingsStore.defaultScreenshotSaveDirectory
        XCTAssertEqual(store.defaults.string(forKey: "screenshot.saveDirectory"), "")
    }

    // MARK: Menu bar

    func testMenuKeyEquivalent() throws {
        let equivalent = try XCTUnwrap(StatusBarMenuSupport.keyEquivalent(for: .defaultScreenshot))
        XCTAssertEqual(equivalent.key, "a")
        XCTAssertEqual(equivalent.modifiers, [.command, .option])

        XCTAssertNil(StatusBarMenuSupport.keyEquivalent(for: .rightCommandActivation))
        XCTAssertNil(StatusBarMenuSupport.keyEquivalent(for: .rightCommandAsk))
        XCTAssertNil(StatusBarMenuSupport.keyEquivalent(for: .defaultAuxiliary))
        // Space has no letter to show.
        XCTAssertNil(StatusBarMenuSupport.keyEquivalent(for: .defaultAsk))
        XCTAssertNil(StatusBarMenuSupport.keyEquivalent(for: HotkeyBinding(keyCode: 0, modifierFlags: 0)))
    }
}

@MainActor
final class ScreenshotSettingsViewModelTests: XCTestCase {
    private func makeViewModel() throws -> (StudioViewModel, SettingsStore) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ScreenshotSettings.\(UUID().uuidString)"))
        let store = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(settingsStore: store, historyStore: ScreenshotTestHistoryStore(),
                                        initialSection: .settings)
        return (viewModel, store)
    }

    func testSetResetAndUnset() throws {
        let (viewModel, store) = try makeViewModel()
        XCTAssertEqual(viewModel.screenshotHotkey, .defaultScreenshot)

        let flags = NSEvent.ModifierFlags.control.union(.shift)
        let custom = HotkeyBinding(keyCode: 1, modifierFlags: UInt(flags.rawValue))
        viewModel.setScreenshotHotkey(custom)
        XCTAssertEqual(store.screenshotHotkey?.signature, custom.signature)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.screenshotUpdated"))

        viewModel.unsetScreenshotHotkey()
        XCTAssertNil(store.screenshotHotkey)
        XCTAssertNil(viewModel.screenshotHotkey)

        viewModel.resetScreenshotHotkey()
        XCTAssertEqual(store.screenshotHotkey?.signature, HotkeyBinding.defaultScreenshot.signature)
    }

    func testScreenshotCannotTakeAnotherShortcut() throws {
        let (viewModel, store) = try makeViewModel()

        viewModel.setScreenshotHotkey(.defaultAsk)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.screenshotConflict"))
        XCTAssertEqual(store.screenshotHotkey, .defaultScreenshot)

        viewModel.setScreenshotHotkey(.defaultAuxiliary)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.auxiliaryConflict"))
    }

    func testOtherShortcutsCannotTakeTheScreenshotShortcut() throws {
        let (viewModel, store) = try makeViewModel()
        let taken = HotkeyBinding.defaultScreenshot

        viewModel.setActivationHotkey(taken)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.usedByScreenshot"))
        viewModel.setAskHotkey(taken)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.usedByScreenshot"))
        viewModel.setPersonaHotkey(taken)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.usedByScreenshot"))
        viewModel.setHistoryHotkey(taken)
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.usedByScreenshot"))
        XCTAssertEqual(store.askHotkey, .defaultAsk)
        XCTAssertEqual(store.historyHotkey, .defaultHistory)

        viewModel.setAuxiliaryHotkey(HotkeyBinding(keyCode: 0, modifierFlags: taken.modifierFlags))
        XCTAssertEqual(viewModel.toastMessage, L("settings.shortcuts.auxiliaryConflict"))
    }

    func testSaveDirectory() throws {
        let (viewModel, store) = try makeViewModel()
        XCTAssertEqual(viewModel.screenshotSaveDirectory, SettingsStore.defaultScreenshotSaveDirectory)

        viewModel.setScreenshotSaveDirectory(URL(fileURLWithPath: "/tmp/Shots", isDirectory: true))
        XCTAssertEqual(store.screenshotSaveDirectory.path, "/tmp/Shots")
        XCTAssertEqual(viewModel.screenshotSaveDirectory.path, "/tmp/Shots")

        viewModel.resetScreenshotSaveDirectory()
        XCTAssertEqual(viewModel.screenshotSaveDirectory, SettingsStore.defaultScreenshotSaveDirectory)
    }
}

private final class ScreenshotTestHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] { [] }
    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] { [] }
    func record(id _: UUID) -> HistoryRecord? { nil }
    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL { URL(fileURLWithPath: "/tmp/typeflux-history.md") }
}
