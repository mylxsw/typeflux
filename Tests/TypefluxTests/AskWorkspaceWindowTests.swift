import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceWindowTests {
    @Test(arguments: InterfaceStyle.allCases)
    func closingALibraryWindowDoesNotBreakTheNextAskToolbar(style: InterfaceStyle) async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        try await closeLibraryWindow(style: style)
        try await Task.sleep(for: .milliseconds(80))
        let suite = "ask-window-rebuild-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let title = String(repeating: "Conversation ", count: 30)
        await fixture.api.seed(.init(id: "rebuild", title: title, revision: 1, updatedAt: Date(), messages: []))
        await fixture.model.refreshHistory()

        // Recreate the entire native window after closing its predecessor.
        for size in [NSSize(width: 1180, height: 760), AskWorkspaceLayout.minimumWindowSize] {
            await fixture.model.select("rebuild")
            let window = makeWindow(size: size)
            let host = NSHostingView(rootView: AskConversationView(model: fixture.model)
                .defaultAppStorage(defaults).environment(\.interfaceStyle, style))
            host.sizingOptions = []
            window.contentView = host
            window.orderFront(nil)
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(400))
            #expect(window.title == title)
            let items = try #require(window.toolbar?.items)
            #expect(!items.contains {
                $0.itemIdentifier == .toggleSidebar
                    || $0.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar")
            })
            #expect(items.filter { $0.itemIdentifier.rawValue.contains("ask.workspace.sidebar") }.count == 1)
            try assertVisibleToolbarFrames(window)
            for identifier in ["ask.workspace.sidebar", "ask.workspace.new"] {
                try await SettingsBehaviorTestSupport.wait("Toolbar action: \(identifier)") {
                    AskWorkspaceTestAccessibility.frame(identifier: identifier, in: window) != nil
                }
                let frame = try #require(AskWorkspaceTestAccessibility.frame(identifier: identifier, in: window))
                #expect(frame.width > 0 && frame.width.isFinite)
                #expect(frame.height > 0 && frame.height.isFinite)
            }
            try AskWorkspaceTestMouse.click(
                at: AskWorkspaceTestAccessibility.center(identifier: "ask.workspace.new", in: window), in: window
            )
            try await fixture.wait { fixture.model.selectedId == nil }
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.model.selectedId == nil)
            #expect(window.title == L("ask.new"))
        }
    }

    @Test func sidebarShortcutKeepsThePreferenceWhenOpeningANarrowDrawer() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let suite = "ask-sidebar-shortcut-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let window = makeWindow(size: NSSize(width: 1180, height: 760))
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model).defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(400))
        try sidebarShortcut(in: window)
        try await SettingsBehaviorTestSupport.wait { defaults.bool(forKey: "ask.sidebarCollapsed") }
        window.setContentSize(NSSize(width: 440, height: 320))
        try await Task.sleep(for: .milliseconds(400))
        try sidebarShortcut(in: window)
        try await SettingsBehaviorTestSupport.wait {
            SettingsBehaviorTestSupport.elements(in: window).contains {
                $0.value("accessibilityIdentifier") as? String == "ask.workspace.drawer.close"
            }
        }
        #expect(defaults.bool(forKey: "ask.sidebarCollapsed"))
    }

    private func sidebarShortcut(in window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                 modifierFlags: [.command, .control],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: "s", charactersIgnoringModifiers: "s",
                                                 isARepeat: false, keyCode: 1))
        #expect(try AppKitTestActions.keyEquivalent(event, in: window))
    }

    private func assertVisibleToolbarFrames(_ window: NSWindow) throws {
        let visible = window.toolbar?.visibleItems ?? []
        for item in visible where item.itemIdentifier.rawValue.contains("ask.workspace.") {
            let frame = try #require(item.view).frame
            #expect(frame.width > 0 && frame.width.isFinite)
            #expect(frame.height > 0 && frame.height.isFinite)
        }
    }

    private func closeLibraryWindow(style: InterfaceStyle) async throws {
        let window = makeWindow(size: NSSize(width: 900, height: 600))
        let view = TypefluxWindow(title: "Settings") { List { Text("History") } } detail: { Text("Content") }
        window.contentView = NSHostingView(rootView: view.environment(\.interfaceStyle, style))
        window.orderFront(nil)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(250))
    }

    private func makeWindow(size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.toolbar = nil
        window.close()
    }
}
