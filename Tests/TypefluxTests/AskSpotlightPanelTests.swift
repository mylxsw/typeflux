import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask Spotlight keyboard routing", .exclusiveUIState)
@MainActor
struct AskSpotlightPanelTests {
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

    @Test func arrowMonitorLeavesMarkedTextAloneAndReleasesItsHandler() throws {
        _ = NSApplication.shared
        let window = AskTestVoiceWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = MarkedEditor(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = editor
        let monitor = AskArrowKeyMonitor.MonitorView()
        var moves: [Int] = []
        monitor.onMove = { moves.append($0) }
        editor.addSubview(monitor)
        window.makeKeyAndOrderFront(nil)
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

    private final class MarkedEditor: NSTextView {
        var marked = false
        override func hasMarkedText() -> Bool { marked }
    }
}
