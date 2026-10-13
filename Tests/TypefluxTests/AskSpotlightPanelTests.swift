import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask Spotlight keyboard routing", .exclusiveUIState)
@MainActor
struct AskSpotlightPanelTests {
    @Test(arguments: [AskLauncherChatAction.openChat, .askAI])
    func headerExposesItsInjectedActionAndOriginalAccessibility(_ mode: AskLauncherChatAction) async throws {
        for style in InterfaceStyle.allCases {
            var actions = 0
            let control = AskLauncherOpenChatButton(mode: mode, enabled: true) { actions += 1 }
            let view = control
                .environment(\.interfaceStyle, style)
                .environment(\.glassMaterialOverride, .opaque)
            try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, _ in
                let button = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == "ask.launcher.openChat"
                })
                #expect(button.role == NSAccessibility.Role.button.rawValue)
                #expect(button.value("accessibilityLabel") as? String == mode.title)
                #expect(button.value("isAccessibilityEnabled") as? Bool == true)
                #expect(button.frame.width == AskSendButton.size)
                #expect(actions == 0)
                // SwiftUI AX presses can enter AppKit's modal tracking loop in the test host.
                control.action()
                #expect(actions == 1)
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func launcherIdentifiersRemainOnTheirControlsAsTheQueryChanges(_ style: InterfaceStyle) async throws {
        let fixture = try AskTestFixture()
        defer {
            fixture.model.resetSession()
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.model.launcherDraft.memory = AskMemory(global: "Context", app: nil)
        let view = AskLauncherView(model: fixture.model, onDismiss: {})
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, _ in
            for query in ["", "Question"] {
                fixture.model.launcherDraft.text = query
                try await Task.sleep(for: .milliseconds(150))
                let elements = SettingsBehaviorTestSupport.elements(in: window)
                for identifier in ["ask.launcher.openChat", "ask.composer.voice", "ask.composer.model",
                                   "ask.context.screenshot.toggle"] {
                    #expect(elements.contains { $0.value("accessibilityIdentifier") as? String == identifier },
                            "Missing original control: \(identifier)")
                }
                for identifier in ["ask.launcher.openChat", "ask.composer.voice"] {
                    let button = try #require(elements.first {
                        $0.value("accessibilityIdentifier") as? String == identifier
                    })
                    #expect(button.role == NSAccessibility.Role.button.rawValue)
                    let diameter = style.usesGlass
                        ? TypefluxControlHeight.spotlightModeButton.value(for: style) : AskMetrics.composerControlHeight
                    #expect(button.frame.width == diameter)
                }
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func searchPaletteRunsActionsAndMatchingConversations(_ style: InterfaceStyle) async throws {
        var actions: [AskPaletteAction] = []
        var opened: [String] = []
        var closed = 0
        let history = [AskConversationSummary(id: "swift", title: "Swift concurrency", updatedAt: Date())]
        let view = AskSearchPaletteView(conversations: history, available: [.newConversation],
                                        onAction: { actions.append($0) }, onOpen: { opened.append($0) },
                                        onClose: { closed += 1 })
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, host in
            let field = try #require(TypefluxNavigationTestSupport.descendants(of: host)
                .compactMap { $0 as? NSTextField }.first { $0.isEditable })
            try TypefluxNavigationTestSupport.focus(field, in: window)
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(actions == [.newConversation])
            try TypefluxNavigationTestSupport.changeText("Swift", in: field)
            try await Task.sleep(for: .milliseconds(150))
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(opened == ["swift"])
            try TypefluxNavigationTestSupport.sendKey(53, to: window)
            #expect(closed == 1)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func searchPaletteArrowsWrapBeforeReturn(_ style: InterfaceStyle) async throws {
        var opened: [String] = []
        let history = [AskConversationSummary(id: "last", title: "Last conversation", updatedAt: Date())]
        let view = AskSearchPaletteView(conversations: history, available: [.newConversation],
                                        onAction: { _ in Issue.record("Expected the conversation") },
                                        onOpen: { opened.append($0) }, onClose: {})
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, host in
            let field = try #require(TypefluxNavigationTestSupport.descendants(of: host)
                .compactMap { $0 as? NSTextField }.first { $0.isEditable })
            try TypefluxNavigationTestSupport.focus(field, in: window)
            try TypefluxNavigationTestSupport.sendKey(126, to: window)
            try await Task.sleep(for: .milliseconds(50))
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(opened == ["last"])
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func commandRowsExposeInjectedActionsAndDisabledReasons(_ style: InterfaceStyle) async throws {
        let commands = [
            AskCommand(action: .help, name: "help", title: "Help", symbol: "questionmark", group: .other),
            AskCommand(action: .help, name: "unavailable", title: "Unavailable", symbol: "lock", group: .other,
                       disabledReason: "Sign in first")
        ]
        var state = AskCommandPaletteState()
        state.update(rows: AskCommandMatcher.filter(commands, query: ""))
        var picked: [Int] = []
        let palette = AskCommandPaletteView(state: state, onPick: { picked.append($0) }, onHighlight: { _ in })
        let view = palette
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { _, host in
            let action = try SettingsBehaviorTestSupport.button("Help", in: host)
            #expect(action.role == NSAccessibility.Role.button.rawValue)
            #expect(action.value("isAccessibilityEnabled") as? Bool == true)
            palette.onPick(0)
            #expect(picked == [0])
            let disabled = try SettingsBehaviorTestSupport.button("Unavailable", in: host)
            #expect(disabled.value("isAccessibilityEnabled") as? Bool == false)
            #expect(disabled.value("accessibilityHelp") as? String == "Sign in first")
        }
    }

    @Test func arrowMonitorLeavesMarkedTextAloneAndReleasesItsHandler() async throws {
        try await TypefluxNavigationTestSupport.withWindow(Color.clear,
                                                           size: NSSize(width: 400, height: 200),
                                                           nonactivating: true) { window, _ in
            let editor = MarkedEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            window.contentView = editor
            let monitor = AskArrowKeyMonitor.MonitorView()
            var moves: [Int] = []
            monitor.onMove = { moves.append($0) }
            editor.addSubview(monitor)
            #expect(window.makeFirstResponder(editor))
            editor.marked = true
            try TypefluxNavigationTestSupport.sendKey(125, to: window)
            #expect(moves.isEmpty)
            editor.marked = false
            try TypefluxNavigationTestSupport.sendKey(125, to: window)
            #expect(moves == [1])
            monitor.removeFromSuperview()
            try TypefluxNavigationTestSupport.sendKey(126, to: window)
            #expect(moves == [1], "Detached monitors must release their event handler")
        }
    }

    @Test func paletteWindowTeardownAllowsANonactivatingClipboardPanelToTakeFocus() async throws {
        let previousPolicy = NSApplication.shared.activationPolicy()
        weak var paletteWindow: NSWindow?
        let view = AskSearchPaletteView(conversations: [], available: [.newConversation],
                                       onAction: { _ in }, onOpen: { _ in }, onClose: {})
        try await TypefluxNavigationTestSupport.withWindow(view, nonactivating: true) { window, host in
            paletteWindow = window
            #expect(window.canBecomeKey && !window.canBecomeMain)
            #expect(window.styleMask.contains(.nonactivatingPanel))
            let field = try #require(TypefluxNavigationTestSupport.descendants(of: host)
                .compactMap { $0 as? NSTextField }.first { $0.isEditable })
            try TypefluxNavigationTestSupport.focus(field, in: window)
        }
        #expect(paletteWindow?.isVisible != true)
        #expect(paletteWindow?.contentView == nil)
        #expect(NSApp.activationPolicy() == previousPolicy)
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let model = ClipboardPanelModel()
            model.reset(entries: [ClipboardTestSupport.entry(.text, text: "Original")])
            let controller = ClipboardPanelController(settingsStore: settings)
            var ownedWindow: NSWindow?
            defer {
                controller.dismiss()
                if let ownedWindow { TypefluxNavigationTestSupport.closeWindow(ownedWindow) }
            }
            controller.present(model)
            let window = try #require(controller.presentedWindow)
            ownedWindow = window
            let host = try #require(window.contentView)
            try await SettingsBehaviorTestSupport.wait {
                TypefluxNavigationTestSupport.searchField(in: host) != nil
            }
            let field = try #require(TypefluxNavigationTestSupport.searchField(in: host))
            try TypefluxNavigationTestSupport.focus(field, in: window)
            #expect(window.canBecomeKey && !window.canBecomeMain)
            #expect(window.styleMask.contains(.nonactivatingPanel))
            #expect(NSApp.activationPolicy() == previousPolicy)
        }
    }

    private final class MarkedEditor: NSTextView {
        var marked = false
        override func hasMarkedText() -> Bool { marked }
    }
}
