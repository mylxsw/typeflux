import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class SettingsMenuPickerTests: XCTestCase {
    func testSharedAndStudioPickersShowOptionsDirectlyAndUpdateSelection() async throws {
        // Native menu tracking must run separately from other window tests.
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_MENU_TESTS"] == "1" else {
            throw XCTSkip("Run with TYPEFLUX_SETTINGS_MENU_TESTS=1 in a dedicated test process")
        }
        _ = NSApplication.shared
        let options = SettingsMenuPickerFixture.options
        for studio in [false, true] {
            let state = SettingsMenuPickerState()
            let content = SettingsMenuPickerFixture(studio: studio, state: state)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content.padding(20))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
            try inspectMenu(using: button) { menu in
                let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                XCTAssertEqual(items.map(\.title), options.map(\.label))
                XCTAssertTrue(items.allSatisfy { $0.submenu == nil }, "Options must be in the first menu")
                XCTAssertEqual(items.filter { $0.state == .on }.map(\.title), ["简体中文"])
                return try XCTUnwrap(menu.items.firstIndex { $0.title == "English" })
            }
            XCTAssertEqual(state.selection, 0)
            try await Task.sleep(for: .milliseconds(100))
            try inspectMenu(using: button) { menu in
                XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), ["English"])
                return nil
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func inspectMenu(using button: NSPopUpButton, check: @escaping (NSMenu) throws -> Int?) throws {
        var inspected = false
        var failure: Error?
        // SwiftUI builds native menu items only when menu tracking begins.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = button.menu else { return }
                menu.cancelTrackingWithoutAnimation()
                do {
                    if let index = try check(menu) {
                        menu.performActionForItem(at: index)
                    }
                    inspected = true
                } catch {
                    failure = error
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        button.performClick(nil)
        timer.invalidate()
        if let failure { throw failure }
        XCTAssertTrue(inspected, "The native menu must open")
    }
}

@MainActor
private final class SettingsMenuPickerState: ObservableObject {
    @Published var selection = 1
}

private struct SettingsMenuPickerFixture: View {
    static let options = [(label: "English", value: 0), (label: "简体中文", value: 1), (label: "日本語", value: 2)]
    let studio: Bool
    @ObservedObject var state: SettingsMenuPickerState

    var body: some View {
        if studio {
            StudioMenuPicker(options: Self.options, selection: $state.selection, width: 280)
        } else {
            SettingsMenuPicker(title: "Language", options: Self.options, selection: $state.selection)
        }
    }
}
