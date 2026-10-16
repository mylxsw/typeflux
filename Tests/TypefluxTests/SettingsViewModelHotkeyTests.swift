import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class SettingsViewModelHotkeyTests: XCTestCase {
    func testHotkeysRefreshWhenSettingsStoreChangesExternally() async throws {
        let suiteName = "SettingsViewModelHotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settingsStore = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(
            settingsStore: settingsStore,
            historyStore: HotkeyTestHistoryStore(),
            initialSection: .settings
        )

        XCTAssertEqual(
            viewModel.activationHotkey?.signature,
            HotkeyBinding.defaultActivation.signature
        )
        XCTAssertEqual(
            viewModel.askHotkey?.signature,
            HotkeyBinding.defaultAsk.signature
        )

        settingsStore.activationHotkey = .rightCommandActivation
        settingsStore.askHotkey = .rightCommandAsk

        try await waitForHotkeys(
            in: viewModel,
            activation: .rightCommandActivation,
            ask: .rightCommandAsk
        )
    }

    private func waitForHotkeys(
        in viewModel: StudioViewModel,
        activation: HotkeyBinding,
        ask: HotkeyBinding
    ) async throws {
        for _ in 0 ..< 50 {
            if viewModel.activationHotkey?.signature == activation.signature,
               viewModel.askHotkey?.signature == ask.signature {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for hotkey settings to refresh")
    }
}

private final class HotkeyTestHistoryStore: HistoryStore {
    func save(record _: HistoryRecord) {}
    func list() -> [HistoryRecord] {
        []
    }

    func list(limit _: Int, offset _: Int, searchQuery _: String?) -> [HistoryRecord] {
        []
    }

    func record(id _: UUID) -> HistoryRecord? {
        nil
    }

    func delete(id _: UUID) {}
    func purge(olderThanDays _: Int) {}
    func clear() {}
    func exportMarkdown() throws -> URL {
        URL(fileURLWithPath: "/tmp/typeflux-history.md")
    }
}


extension SettingsViewModelHotkeyTests {
    func testAuxiliaryConflictsAreCheckedInBothDirectionsAndPersonaIsIndependent() throws {
        let name = "SettingsViewModelHotkeyTests.auxiliary.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let model = StudioViewModel(settingsStore: store, historyStore: HotkeyTestHistoryStore(), initialSection: .settings)
        model.setAuxiliaryHotkey(.defaultAsk)
        XCTAssertEqual(store.auxiliaryHotkey?.signature, HotkeyBinding.defaultAuxiliary.signature)
        model.setAuxiliaryHotkey(.rightOptionActivation)
        let before = [store.activationHotkey, store.askHotkey, store.personaHotkey, store.historyHotkey].map { $0?.signature }
        model.setActivationHotkey(.rightOptionActivation)
        model.setAskHotkey(.rightOptionActivation)
        model.setPersonaHotkey(.rightOptionActivation)
        model.setHistoryHotkey(.rightOptionActivation)
        XCTAssertEqual([store.activationHotkey, store.askHotkey, store.personaHotkey, store.historyHotkey].map { $0?.signature }, before)
        let mainID = store.activePersonaID
        model.setAuxiliaryPersona(SettingsStore.defaultPersonaID.uuidString)
        XCTAssertEqual(store.auxiliaryPersona.id, SettingsStore.defaultPersonaID)
        XCTAssertEqual(store.activePersonaID, mainID)
        model.unsetAuxiliaryHotkey()
        XCTAssertNil(store.auxiliaryHotkey)
        model.resetAuxiliaryHotkey()
        XCTAssertEqual(store.auxiliaryHotkey?.signature, HotkeyBinding.defaultAuxiliary.signature)
    }

    func testAuxiliarySettingsRenderBesideVoiceInput() throws {
        let name = "SettingsViewModelHotkeyTests.render.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = StudioViewModel(settingsStore: SettingsStore(defaults: defaults), historyStore: HotkeyTestHistoryStore(), initialSection: .settings)
        let size = CGSize(width: 1100, height: 2100)
        let view = StudioView(viewModel: model).frame(width: size.width, height: size.height).preferredColorScheme(.light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/typeflux-aux-settings.png"))
        XCTAssertEqual(host.frame.size, size)
    }
}
