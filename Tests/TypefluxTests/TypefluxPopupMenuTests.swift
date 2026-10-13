import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

@MainActor
final class TypefluxPopupMenuTests: XCTestCase {
    func testUnavailableSelectionKeepsItsLabelUntilAValidOptionIsChosen() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_MENU_TESTS"] == "1" else {
            throw XCTSkip("Run native menu tracking in a dedicated test process")
        }
        let previousPolicy = activateTestApplication()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        for options in [TypefluxPopupMenuFixture.options, []] {
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var selected = 99
            let host = NSHostingView(rootView: TypefluxPopup(title: "Unavailable model", options: options,
                selection: Binding(get: { selected }, set: { selected = $0 })).padding(20))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertEqual(button.title, "Unavailable model")
            if !options.isEmpty {
                try inspectMenu(using: button) { menu in
                    let item = try XCTUnwrap(menu.items.first { $0.title == "Unavailable model" })
                    XCTAssertEqual(item.state, .on)
                    XCTAssertEqual(selected, 99)
                    return try XCTUnwrap(menu.items.firstIndex { $0.title == "English" })
                }
                XCTAssertEqual(selected, 0)
            }
        }
    }

    func testSharedAndStudioPickersShowOptionsDirectlyAndUpdateSelection() async throws {
        // Native menu tracking must run separately from other window tests.
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SETTINGS_MENU_TESTS"] == "1" else {
            throw XCTSkip("Run with TYPEFLUX_SETTINGS_MENU_TESTS=1 in a dedicated test process")
        }
        let previousPolicy = activateTestApplication()
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let options = TypefluxPopupMenuFixture.options
        for studio in [false, true] {
            let state = TypefluxPopupMenuState()
            let content = TypefluxPopupMenuFixture(studio: studio, state: state)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content.padding(20))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertGreaterThan(button.bounds.width, 0)
            XCTAssertGreaterThan(button.bounds.height, 0)
            let bounds = button.bounds
            let clickPoints = [NSPoint(x: bounds.midX, y: bounds.midY)]
            for point in clickPoints {
                let hostPoint = host.convert(point, from: button)
                XCTAssertTrue(
                    host.hitTest(hostPoint) === button,
                    "The native menu must receive a click at \(point)"
                )
                try inspectMenu(using: button, clickAt: point) { menu in
                    XCTAssertEqual(menu.items.count, options.count)
                    return nil
                }
            }
            // Let AppKit finish closing the previous tracking loop before reopening the control.
            try await Task.sleep(for: .milliseconds(200))
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

    private func activateTestApplication() -> NSApplication.ActivationPolicy {
        _ = NSApplication.shared
        let previous = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        return previous
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func inspectMenu(
        using button: NSPopUpButton,
        clickAt point: NSPoint? = nil,
        check: @escaping (NSMenu) throws -> Int?
    ) throws {
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
        if let point, let window = button.window {
            let location = button.convert(point, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                                        modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(down)
            let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                                                      modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 1, clickCount: 1, pressure: 0))
            window.sendEvent(mouseUp)
        } else {
            button.performClick(nil)
        }
        timer.invalidate()
        if let failure {
            throw failure
        }
        XCTAssertTrue(inspected, "The native menu must open")
    }
}

@MainActor
private final class TypefluxPopupMenuState: ObservableObject {
    @Published var selection = 1
}

private struct TypefluxPopupMenuFixture: View {
    static let options = [(label: "English", value: 0), (label: "简体中文", value: 1), (label: "日本語", value: 2)]
    let studio: Bool
    @ObservedObject var state: TypefluxPopupMenuState

    var body: some View {
        if studio {
            StudioMenuPicker(options: Self.options, selection: $state.selection, width: 280)
        } else {
            TypefluxPopup(title: "Language", options: Self.options, selection: $state.selection).frame(width: 280)
        }
    }
}
