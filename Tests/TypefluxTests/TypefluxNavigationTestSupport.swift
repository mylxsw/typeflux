import AppKit
import SwiftUI
import Testing
@testable import TypefluxUI

@MainActor
enum TypefluxNavigationTestSupport {
    static func withWindow(_ view: some View, size: NSSize = NSSize(width: 900, height: 600),
                           run: (NSWindow, NSView) async throws -> Void) async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet); sheet.close()
            }
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
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
            // SwiftPM does not run NSApp's event loop. Ask the owned native
            // window to resolve its default/cancel button keyboard equivalents.
            _ = window.performKeyEquivalent(with: event)
        } else {
            NSApp.sendEvent(event)
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
