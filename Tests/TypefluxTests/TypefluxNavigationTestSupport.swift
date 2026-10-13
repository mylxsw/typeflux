import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@MainActor
enum TypefluxNavigationTestSupport {
    @MainActor
    final class HostedWindow {
        let window: NSWindow
        let host: NSView
        private var closed = false

        init(window: NSWindow, host: NSView) {
            self.window = window
            self.host = host
        }

        func detach() {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet); sheet.close()
            }
            window.contentView = nil
        }

        func close() {
            guard !closed else { return }
            closed = true
            detach()
            window.orderOut(nil)
            window.close()
        }
    }

    static func prepareApplication() {
        TypefluxTestApplicationEnvironment.prepare()
    }

    static func closeWindow(_ window: NSWindow) {
        if AskGlassMenuPresenter.shared.panel?.parent === window { AskGlassMenuPresenter.shared.hide() }
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
            sheet.close()
        }
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            child.contentView = nil
            child.orderOut(nil)
            child.close()
        }
        // AppKit releases key status while the responder tree is still attached.
        window.orderOut(nil)
        window.makeFirstResponder(nil)
        window.contentView = nil
        window.close()
    }

    static func withWindow(_ view: some View, size: NSSize = NSSize(width: 900, height: 600),
                           nonactivating: Bool = false,
                           run: (NSWindow, NSView) async throws -> Void) async throws {
        if nonactivating {
            try await withNonactivatingPanel(view, size: size, run: run)
            return
        }
        try await withWindows([AnyView(view)], size: size) { windows in
            let hosted = try #require(windows.first)
            try await run(hosted.window, hosted.host)
        }
    }

    /// Fixtures own their windows; application configuration is performed once for the process.
    static func withWindows(_ views: [AnyView], size: NSSize = NSSize(width: 900, height: 600),
                            run: @MainActor ([HostedWindow]) async throws -> Void) async throws {
        _ = try #require(!views.isEmpty)
        TypefluxTestApplicationEnvironment.prepare()
        let windows = views.map { makeWindow($0, size: size) }
        defer { close(windows) }
        for hosted in windows { hosted.window.orderFront(nil) }
        windows.last?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(250))
        windows.last?.window.makeKey()
        for hosted in windows { hosted.host.layoutSubtreeIfNeeded() }
        try await run(windows)
    }

    private static func makeWindow(_ view: AnyView, size: NSSize) -> HostedWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        return HostedWindow(window: window, host: host)
    }

    private static func close(_ windows: [HostedWindow]) {
        // Stop every hosting tree before closing a key window can activate another test window.
        for hosted in windows { hosted.detach() }
        for hosted in windows.reversed() { hosted.close() }
    }

    /// Spotlight-style fixtures need a non-activating panel that keeps the runner's activation policy.
    private static func withNonactivatingPanel(_ view: some View, size: NSSize,
                                               run: (NSWindow, NSView) async throws -> Void) async throws {
        prepareApplication()
        let rect = NSRect(origin: NSPoint(x: 100, y: 100), size: size)
        let window = TypefluxNonactivatingTestPanel(contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { closeWindow(window) }
        try await Task.sleep(for: .milliseconds(250))
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        try await run(window, host)
    }

    static func searchField(in view: NSView, identifier: String? = nil) -> NSSearchField? {
        if let field = view as? NSSearchField,
           identifier == nil || field.accessibilityIdentifier() == identifier {
            return field
        }
        return view.subviews.lazy.compactMap { searchField(in: $0, identifier: identifier) }.first
    }

    static func toggleSidebar(in window: NSWindow) throws {
        let item = try #require(window.toolbar?.items.first {
            $0.itemIdentifier == .toggleSidebar
                || $0.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar")
        }, "Missing native sidebar toolbar item")
        window.makeKeyAndOrderFront(nil)
        if let view = item.view,
           let button = SettingsBehaviorTestSupport.elements(in: view).first(where: {
               $0.role == NSAccessibility.Role.button.rawValue
           }) {
            try button.press()
        } else {
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
    }

    static func sendKey(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [],
                        to window: NSWindow, keyEquivalent: Bool = false) throws {
        let text: String = if !characters.isEmpty {
            characters
        } else {
            switch code {
            case 36, 76: "\r"
            case 53: "\u{1b}"
            case 125: "\u{f701}"
            case 126: "\u{f700}"
            default: ""
            }
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: text, charactersIgnoringModifiers: text,
                                                  isARepeat: false, keyCode: code))
        if keyEquivalent {
            // Prefer native shortcut wiring; SwiftUI shortcuts can exist without an NSButtonCell equivalent.
            let flags = modifiers.intersection([.command, .option, .control, .shift])
            let controls = window.contentView.map(SettingsBehaviorTestSupport.nativeViews) ?? []
            let matching = controls.compactMap { $0 as? NSControl }.first {
                guard !($0 is NSPopUpButton), let cell = $0.cell as? NSButtonCell,
                      !(cell is NSPopUpButtonCell), !$0.isHiddenOrHasHiddenAncestor else { return false }
                return cell.keyEquivalent == text
                    && cell.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == flags
            }
            if let control = matching {
                try SettingsBehaviorTestSupport.Element(object: control, window: window).press()
            } else {
                // Route through this window's SwiftUI hosting tree, then consume delayed runloop stops
                // just as pressThroughAccessibility does. Callers assert the actual command's effect.
                defer { SettingsBehaviorTestSupport.drainPendingRunLoopStops() }
                _ = window.performKeyEquivalent(with: event)
            }
            return
        }
        // Swift Testing does not run NSApp.run. Dispatch the same owned handlers that the local
        // monitors use, without relying on WindowServer's key-window event delivery.
        guard window.attachedSheet == nil, let content = window.contentView else { return }
        for view in SettingsBehaviorTestSupport.nativeViews(in: content) {
            if let bridge = view as? TypefluxSearchToolbarBridge.BridgeView, bridge.handle(event) {
                if modifiers == .command, text.lowercased() == "f",
                   let field = window.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first?.searchField {
                    #expect(window.makeFirstResponder(field), "Focus the search field in its owning window")
                }
                return
            }
            if let monitor = view as? TypefluxKeyboardMonitor.MonitorView, monitor.handle(event) { return }
            if let table = view as? TypefluxTableDeleteKey.KeyView, table.handle(event) { return }
        }
    }

    static func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_UI_SNAPSHOTS"] else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Cache the native frame and content without requiring Screen Recording
        // access. WindowServer's glass compositor needs an additional live check.
        let view = try #require(window.contentView?.superview)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        try png.write(to: file)
        if ProcessInfo.processInfo.environment["TYPEFLUX_UI_CAPTURE_LIVE"] == "1" {
            let live = file.deletingLastPathComponent().appendingPathComponent(name + "-live.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), live.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(try Data(contentsOf: live).count > 1000)
        }
    }
}
