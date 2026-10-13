import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask Spotlight keyboard routing", .exclusiveUIState)
@MainActor
struct AskSpotlightPanelTests {
    @Test(arguments: [AskLauncherChatAction.openChat, .askAI])
    func headerMouseDownReturnsBeforeTheCallerDeliversMouseUp(_ mode: AskLauncherChatAction) async throws {
        for style in InterfaceStyle.allCases {
            var actions = 0
            let view = TypefluxSpotlightModeControl {
                AskLauncherOpenChatButton(mode: mode, enabled: true) { actions += 1 }
            }
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
            try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
                let button = try #require(SettingsBehaviorTestSupport.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == "ask.launcher.openChat"
                })
                let point = window.convertPoint(fromScreen: NSPoint(x: button.frame.midX, y: button.frame.midY))
                let mouseDown = try mouseEvent(.leftMouseDown, at: point, in: window)
                let mouseUp = try mouseEvent(.leftMouseUp, at: point, in: window)
                let release = MouseReleaseWatchdog(event: mouseUp)
                // A native modal tracking loop must fail this test instead of hanging the entire suite.
                let timer = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { release.fire() }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                NSApp.sendEvent(mouseDown)
                timer.invalidate()
                try #require(!release.fired, "Mouse-down waited for mouse-up in a modal tracking loop")
                #expect(actions == 0)
                NSApp.sendEvent(mouseUp)
                try await Task.sleep(for: .milliseconds(150))
                #expect(actions == 1, "Releasing the original header control must invoke its action once")
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
        try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
            for query in ["", "Question"] {
                fixture.model.launcherDraft.text = query
                try await Task.sleep(for: .milliseconds(150))
                let elements = SettingsBehaviorTestSupport.elements(in: window)
                for identifier in ["ask.launcher.openChat", "ask.composer.voice", "ask.composer.model",
                                   "ask.context.screenshot.toggle"] {
                    #expect(elements.contains { $0.value("accessibilityIdentifier") as? String == identifier },
                            "Missing original control: \(identifier)")
                }
                let button = try #require(elements.first {
                    $0.value("accessibilityIdentifier") as? String == "ask.launcher.openChat"
                })
                #expect(button.role == NSAccessibility.Role.button.rawValue)
                #expect(button.frame.width == AskSendButton.size)
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
        try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
            let editor = try #require(window.firstResponder as? NSTextView)
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(actions == [.newConversation])
            editor.insertText("Swift", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
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
        try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
            try TypefluxNavigationTestSupport.sendKey(126, to: window)
            try await Task.sleep(for: .milliseconds(50))
            try TypefluxNavigationTestSupport.sendKey(36, to: window)
            #expect(opened == ["last"])
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func commandRowsExposeNativeActionsAndDisabledReasons(_ style: InterfaceStyle) async throws {
        let commands = [
            AskCommand(action: .help, name: "help", title: "Help", symbol: "questionmark", group: .other),
            AskCommand(action: .help, name: "unavailable", title: "Unavailable", symbol: "lock", group: .other,
                       disabledReason: "Sign in first")
        ]
        var state = AskCommandPaletteState()
        state.update(rows: AskCommandMatcher.filter(commands, query: ""))
        var picked: [Int] = []
        let view = AskCommandPaletteView(state: state, onPick: { picked.append($0) }, onHighlight: { _ in })
            .environment(\.interfaceStyle, style)
            .environment(\.glassMaterialOverride, .opaque)
        try await TypefluxNavigationTestSupport.withWindow(view) { _, host in
            let action = try SettingsBehaviorTestSupport.button("Help", in: host)
            try action.press()
            #expect(picked == [0])
            let disabled = try SettingsBehaviorTestSupport.button("Unavailable", in: host)
            #expect(disabled.value("isAccessibilityEnabled") as? Bool == false)
            #expect(disabled.value("accessibilityHelp") as? String == "Sign in first")
        }
    }

    @Test func arrowMonitorLeavesMarkedTextAloneAndReleasesItsHandler() async throws {
        try await TypefluxNavigationTestSupport.withWindow(Color.clear,
                                                           size: NSSize(width: 400, height: 200)) { window, _ in
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
        weak var paletteWindow: NSWindow?
        let view = AskSearchPaletteView(conversations: [], available: [.newConversation],
                                       onAction: { _ in }, onOpen: { _ in }, onClose: {})
        try await TypefluxNavigationTestSupport.withWindow(view) { window, _ in
            paletteWindow = window
            #expect(window.isKeyWindow)
        }
        #expect(paletteWindow?.isVisible != true)
        #expect(paletteWindow?.contentView == nil)
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
                guard let field = TypefluxNavigationTestSupport.searchField(in: host),
                      let editor = field.currentEditor() else { return false }
                return window.isKeyWindow && window.firstResponder === editor
            }
            #expect(window.styleMask.contains(.nonactivatingPanel))
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    @MainActor private final class MouseReleaseWatchdog {
        private let event: NSEvent
        private(set) var fired = false

        init(event: NSEvent) { self.event = event }

        func fire() {
            fired = true
            NSApp.postEvent(event, atStart: true)
        }
    }

    private final class MarkedEditor: NSTextView {
        var marked = false
        override func hasMarkedText() -> Bool { marked }
    }
}
