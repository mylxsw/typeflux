import AppKit
import SwiftUI
import XCTest
@testable import Typeflux

final class ClipboardPanelNumberShortcutTests: XCTestCase {
    @MainActor
    private func window() throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first {
            $0.isVisible && $0.identifier?.rawValue == "ai.gulu.app.typeflux.window.clipboard"
        })
    }

    @MainActor
    private func monitor(in view: NSView) -> AskLauncherCommandMonitor.MonitorView? {
        (view as? AskLauncherCommandMonitor.MonitorView) ?? view.subviews.lazy.compactMap { self.monitor(in: $0) }.first
    }

    @MainActor
    func testControllerPastesTheNumberedSearchResultOnce() throws {
        let suite = "ClipboardNumbers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ClipboardPanelController(settingsStore: SettingsStore(defaults: defaults))
        defer { controller.dismiss() }
        let model = ClipboardPanelModel()
        model.reset(entries: [
            ClipboardTestSupport.entry(.voice, text: "voice match"),
            ClipboardTestSupport.entry(.text, text: "unrelated"),
            ClipboardTestSupport.entry(.text, text: "text match")
        ])
        var pasted: [String] = []
        model.onAction = { action, entry in
            XCTAssertEqual(action, .paste)
            pasted.append(entry.title)
        }
        controller.present(model)
        let panel = try window()
        model.query = "match"
        @MainActor func press(_ number: String, flags: NSEvent.ModifierFlags = .command, repeatKey: Bool = false) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: number,
                charactersIgnoringModifiers: number, isARepeat: repeatKey, keyCode: 19
            ))
            return controller.handleKeyDown(event)
        }
        XCTAssertTrue(try press("2"))
        XCTAssertEqual(pasted, ["text match"])
        XCTAssertTrue(try press("2", repeatKey: true))
        XCTAssertTrue(try press("9"))
        XCTAssertFalse(try press("2", flags: []))
        XCTAssertFalse(try press("2", flags: [.command, .shift]))
        XCTAssertEqual(pasted, ["text match"])
        model.category = .text
        XCTAssertTrue(try press("1"))
        XCTAssertEqual(pasted, ["text match", "text match"])
    }

    @MainActor
    func testCommandHintsAppearReleaseAndClearOnDismiss() async throws {
        let suite = "ClipboardNumberHints.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let model = ClipboardPanelModel()
        model.reset(entries: (1...10).map { ClipboardTestSupport.entry(.text, text: "Clipboard item \($0)") })
        let controller = ClipboardPanelController(settingsStore: settings)
        defer { controller.dismiss() }
        let directory = ProcessInfo.processInfo.environment["TYPEFLUX_CLIPBOARD_NUMBER_SNAPSHOTS"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for (mode, appearance) in [("light", AppearanceMode.light), ("dark", .dark)] {
            settings.appearanceMode = appearance
            controller.present(model)
            let panel = try window()
            try await Task.sleep(for: .milliseconds(80))
            let content = try XCTUnwrap(panel.contentView)
            let observer = try XCTUnwrap(monitor(in: content))
            let originalSize = panel.frame.size
            var renders: [Data] = []
            for (name, modifiers) in [("idle", NSEvent.ModifierFlags()), ("held", .command), ("released", [])] {
                observer.update(modifiers: modifiers, isKeyWindow: true)
                try await Task.sleep(for: .milliseconds(60))
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(observer.showing, name == "held")
                XCTAssertEqual(panel.frame.size, originalSize)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                renders.append(png)
                if let directory {
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("clipboard-\(mode)-\(name).png"))
                }
            }
            XCTAssertNotEqual(renders[0], renders[1])
            XCTAssertNotEqual(renders[1], renders[2])
            observer.update(modifiers: .command, isKeyWindow: true)
            controller.dismiss()
            XCTAssertFalse(observer.showing)
        }
    }
}
