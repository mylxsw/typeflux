import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceWindowTests {
    @Test(arguments: InterfaceStyle.allCases)
    func trailingActionsStayBesideSearchAndNewRunsItsOwnedAction(style: InterfaceStyle) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        await fixture.api.seed(.init(id: "toolbar", title: "Toolbar conversation", revision: 1,
                                    updatedAt: .now, messages: []))
        await fixture.model.refreshHistory()
        await fixture.model.select("toolbar")
        let content = AskConversationView(model: fixture.model).environment(\.interfaceStyle, style)
        try await TypefluxNavigationTestSupport.withWindow(content, size: NSSize(width: 1180, height: 760)) {
            window, _ in
            try await SettingsBehaviorTestSupport.wait("Trailing Ask toolbar") {
                AskWorkspaceTestAccessibility.frame(identifier: "ask.workspace.new", in: window) != nil
                    && window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true
            }
            layout(window)
            let toolbar = try #require(window.toolbar)
            let actions = try #require(toolbar.items.first { $0.itemIdentifier.rawValue.contains("ask.actions") })
            let new = try #require(AskWorkspaceTestAccessibility.frame(identifier: "ask.workspace.new", in: window))
            let search = try #require(toolbar.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField)
            let group = try #require(actions.view)
            let groupFrame = window.convertToScreen(group.convert(group.bounds, to: nil))
            let searchFrame = window.convertToScreen(search.convert(search.bounds, to: nil))
            #expect(groupFrame.maxX <= new.minX && new.maxX <= searchFrame.minX)
            #expect(searchFrame.minX - new.maxX <= TypefluxControlWidth.toolbarItem.value(for: style) * 2)
            let groupIndex = try #require(toolbar.items.firstIndex { $0 === actions })
            #expect(!toolbar.items.dropFirst(groupIndex).contains { $0.itemIdentifier == .flexibleSpace })
            let newItem = try #require(toolbar.items.first {
                $0.itemIdentifier.rawValue.contains("ask.workspace.new")
            })
            let newRoot = try #require(newItem.view)
            _ = try SettingsBehaviorTestSupport.button(L("ask.new"), in: newRoot)
            // The shared SwiftUI control owns its native target/action. Exercise the same model command.
            fixture.model.newConversation()
            try await SettingsBehaviorTestSupport.wait("New conversation toolbar action") {
                fixture.model.selectedId == nil
            }
            await fixture.model.select("toolbar")
            try TypefluxNavigationTestSupport.sendKey(45, characters: "n", modifiers: .command,
                                                       to: window, keyEquivalent: true)
            try await SettingsBehaviorTestSupport.wait("New conversation keyboard shortcut") {
                fixture.model.selectedId == nil
            }
        }
    }

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
            window.makeKeyAndOrderFront(nil)
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(400))
            layout(window)
            #expect(window.title == title)
            #expect(window.titleVisibility == .hidden)
            let items = try #require(window.toolbar?.items)
            #expect(!items.contains {
                $0.itemIdentifier == .toggleSidebar
                    || $0.itemIdentifier.rawValue.localizedCaseInsensitiveContains("toggleSidebar")
            })
            #expect(items.filter { $0.itemIdentifier.rawValue.contains("ask.workspace.sidebar") }.count == 1)
            try assertVisibleToolbarFrames(window)
            for identifier in ["ask.workspace.sidebar", "ask.workspace.new"] {
                try await SettingsBehaviorTestSupport.wait("Toolbar action: \(identifier)") {
                    layout(window)
                    return AskWorkspaceTestAccessibility.frame(identifier: identifier, in: window) != nil
                }
                let frame = try #require(AskWorkspaceTestAccessibility.frame(identifier: identifier, in: window))
                #expect(frame.width > 0 && frame.width.isFinite)
                #expect(frame.height > 0 && frame.height.isFinite)
                #expect(window.frame.contains(frame), "The primary action must remain inside the window")
            }
            try AskWorkspaceTestAccessibility.assertButton("ask.workspace.new", label: L("ask.new"), in: window)
            fixture.model.newConversation()
            try await fixture.wait { fixture.model.selectedId == nil }
            try await Task.sleep(for: .milliseconds(100))
            #expect(fixture.model.selectedId == nil)
            #expect(window.title == L("ask.new"))
        }
    }

    @Test func sidebarStateKeepsThePreferenceWhenOpeningANarrowDrawer() async throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let suite = "ask-sidebar-shortcut-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let window = makeWindow(size: NSSize(width: 1180, height: 760))
        let presentation = AskWorkspaceState()
        let hosting = NSHostingView(rootView: AskConversationView(model: fixture.model, presentation: presentation)
            .defaultAppStorage(defaults))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(400))
        layout(window)
        try sidebarAction(presentation, defaults: defaults, in: window)
        try await SettingsBehaviorTestSupport.wait { defaults.bool(forKey: "ask.sidebarCollapsed") }
        window.setContentSize(NSSize(width: 440, height: 320))
        try await Task.sleep(for: .milliseconds(400))
        layout(window)
        try sidebarAction(presentation, defaults: defaults, in: window)
        try await SettingsBehaviorTestSupport.wait {
            SettingsBehaviorTestSupport.elements(in: window).contains {
                $0.value("accessibilityIdentifier") as? String == "ask.workspace.drawer.close"
            }
        }
        #expect(defaults.bool(forKey: "ask.sidebarCollapsed"))
    }

    private func sidebarAction(_ presentation: AskWorkspaceState, defaults: UserDefaults,
                               in window: NSWindow) throws {
        try AskWorkspaceTestAccessibility.assertButton("ask.workspace.sidebar",
                                                      label: L("ask.sidebar.toggle"), in: window)
        let collapsed = defaults.bool(forKey: "ask.sidebarCollapsed")
        let size = try #require(window.contentView).bounds.size
        presentation.toggleSidebar(layout: AskWorkspaceLayout(size: size, sidebarCollapsed: collapsed,
            showsUsage: presentation.showsUsage), collapsed: collapsed, reduceMotion: false) {
            defaults.set($0, forKey: "ask.sidebarCollapsed")
        }
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

    private func layout(_ window: NSWindow) {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.toolbar = nil
        window.close()
    }
}
