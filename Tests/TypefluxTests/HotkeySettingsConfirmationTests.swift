import AppKit
import SwiftUI
import XCTest
@testable import Typeflux

@MainActor
final class HotkeySettingsConfirmationTests: XCTestCase {
    private typealias Support = SettingsBehaviorTestSupport

    func testResetUnsetAndDeleteChangeOnlyAfterConfirmation() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_HOTKEY_MENUS"] == "1" else {
            throw XCTSkip("Run native menu tracking in a dedicated test process")
        }
        try await Support.withFixture { settings in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let model = StudioViewModel(settingsStore: settings, historyStore: FileHistoryStore(baseDir: root),
                initialSection: .settings,
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false))
            let custom = HotkeyBinding(keyCode: 15, modifierFlags: UInt(NSEvent.ModifierFlags.control.rawValue))
            model.setActivationHotkey(custom)
            XCTAssertEqual(settings.hotkey(.activation), custom)
            let shortcut = KeywordHotkey(binding: .defaultAsk, keyword: "fy", pluginID: AskTranslatePlugin.id)
            settings.keywordHotkeys = [shortcut]
            try await Support.withWindow(HotkeySettingsView(viewModel: model, settingsStore: settings),
                                    width: 640, height: 1000) { window, host in
                window.setFrameOrigin(NSPoint(x: 100, y: 50))
                try await Task.sleep(for: .milliseconds(150))
                try await confirmMenuAction("hotkeys.menu.reset", row: "builtIn.activation", window: window,
                                            host: host, unchanged: { settings.hotkey(.activation) == custom })
                try await Support.wait { settings.hotkey(.activation) == .defaultActivation }
                try await confirmMenuAction("settings.shortcuts.unset", row: "builtIn.activation", window: window,
                    host: host, unchanged: { settings.hotkey(.activation) == .defaultActivation })
                try await Support.wait { settings.hotkey(.activation) == nil }
                try await confirmMenuAction("hotkeys.keyword.delete", row: "keyword." + shortcut.id.uuidString,
                    window: window, host: host, unchanged: { settings.keywordHotkeys == [shortcut] })
                try await Support.wait { settings.keywordHotkeys.isEmpty }
            }
        }
    }

    private func confirmMenuAction(_ key: String, row: String, window: NSWindow, host: NSView,
                                   unchanged: () -> Bool) async throws {
        try selectMenuItem(L(key), row: row, in: host)
        try await Support.wait { window.attachedSheet != nil }
        XCTAssertTrue(unchanged())
        try Support.button(L("common.cancel"), in: try XCTUnwrap(window.attachedSheet)).press()
        try await Support.wait { window.attachedSheet == nil }
        XCTAssertTrue(unchanged())
        try selectMenuItem(L(key), row: row, in: host)
        try await Support.wait { window.attachedSheet != nil }
        XCTAssertTrue(unchanged())
        try Support.button(L(key), in: try XCTUnwrap(window.attachedSheet)).press()
        try await Support.wait { window.attachedSheet == nil }
    }

    private func selectMenuItem(_ title: String, row: String, in host: NSView) throws {
        let element = try XCTUnwrap(Support.elements(in: host).first {
            $0.value("accessibilityIdentifier") as? String == "hotkeys.row." + row
        })
        let window = try XCTUnwrap(host.window)
        let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first {
            element.frame.intersects(window.convertToScreen($0.convert($0.bounds, to: nil)))
        })
        var selected = false
        // SwiftUI creates commands only inside the native menu tracking loop.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu else { return }
                let index = menu.items.firstIndex { $0.title == title && $0.isEnabled }
                menu.cancelTrackingWithoutAnimation()
                if let index { menu.performActionForItem(at: index); selected = true }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        button.performClick(nil)
        XCTAssertTrue(selected, "The shortcut menu must dispatch \(title)")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
