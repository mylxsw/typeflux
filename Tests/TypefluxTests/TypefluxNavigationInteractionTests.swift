import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

/// Run separately from bitmap rendering: the native window lifecycle can terminate
/// SwiftPM's current async runner before subsequent offscreen renders.
@Suite(.serialized, .exclusiveUIState,
       .enabled(if: ProcessInfo.processInfo.environment["TYPEFLUX_UI_NAVIGATION_LIVE"] == "1"))
@MainActor
struct TypefluxNavigationInteractionTests {
    @Test func `native toolbar search supports command F typing Escape and blur`() async throws {
        let state = TypefluxSearchState()
        let view = TypefluxWindow(title: "Notes", items: [
            TypefluxNavigationItem(id: "all", title: "All", systemImage: "note.text", count: 12),
            TypefluxNavigationItem(id: "other", title: "Other", systemImage: "doc")
        ], selection: .constant("all"), search: state, searchPrompt: "Search Notes",
        groups: [TypefluxToolbarGroup(id: "navigation", actions: [
            TypefluxToolbarAction(id: "back", title: "Back", systemImage: "chevron.left") {},
            TypefluxToolbarAction(
                id: "disabled",
                title: "Unavailable",
                systemImage: "trash",
                isEnabled: false
            ) {}
        ])],
        prominent: TypefluxToolbarAction(id: "new", title: "New", systemImage: "plus") {}) {
            Text("Solid reading column")
        }
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                try await TypefluxNavigationTestSupport.withWindow(view.environment(\.interfaceStyle, style)
                    .environment(\.colorScheme, dark ? .dark : .light)) { window, _ in
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        try await SettingsBehaviorTestSupport
                            .wait { window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true }
                        let item = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
                        try TypefluxNavigationTestSupport.capture(
                            window,
                            name: "window-\(style.rawValue)-\(dark ? "dark" : "light")"
                        )
                        try await verifyNativeSearch(state: state, item: item, window: window)
                    }
            }
        }
    }

    @Test func `standalone search native delegate synchronizes and does not replace input method Escape`() async throws {
        let state = TypefluxSearchState()
        try await TypefluxNavigationTestSupport.withWindow(TypefluxToolbarSearch(
            state: state,
            prompt: "Search"
        )) { window, host in
            try SettingsBehaviorTestSupport.button("Search", in: host).press()
            try await SettingsBehaviorTestSupport.wait { state.isExpanded }
            let field = try #require(TypefluxNavigationTestSupport.searchField(in: host))
            #expect(field.frame.height <= max(22, field.intrinsicContentSize.height))
            #expect((field.cell as? NSSearchFieldCell)?.searchButtonCell == nil)
            window.makeFirstResponder(field)
            try await SettingsBehaviorTestSupport.wait { state.isFocused }
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("value", replacementRange: NSRange(location: 0, length: 0))
            try await SettingsBehaviorTestSupport.wait { state.query == "value" }
            let coordinator = try #require(field.delegate as? TypefluxNativeSearchField.Coordinator)
            #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
            editor.setMarkedText(
                "composition",
                selectedRange: NSRange(location: 0, length: 1),
                replacementRange: NSRange(location: 0, length: 0)
            )
            #expect(!coordinator.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ))
            editor.unmarkText()
            state.query = "value"
            #expect(coordinator.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ))
            #expect(state.query.isEmpty && state.isExpanded)
            #expect(coordinator.control(
                field,
                textView: editor,
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            ))
            #expect(!state.isExpanded)
            try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
            #expect(state.isExpanded)
        }
    }

    @Test func `spotlight shortcuts mode selection and window isolation work`() async throws {
        var activations: [(String, Bool)] = []
        var dismissals = 0
        var selectedMode = "all"
        let items = (1 ... 10).map { TypefluxSpotlightItem(id: String($0), title: "Result \($0)",
                                                           subtitle: $0 == 1 ? "Subtitle" : nil, isEnabled: $0 != 2) }
        let modes = TypefluxNavigationGalleryExamples.modes
        let size = NSSize(width: 660, height: 420)
        let view = TypefluxSpotlightPanel(
            query: .constant(""),
            mode: Binding(get: { selectedMode }, set: { selectedMode = $0 }),
            prompt: "Search",
            items: items,
            modes: modes,
            emptyText: "Empty",
            hints: ["↑↓", "↵", "⌘↵", "⌘1–9", "Esc"],
            activate: { activations.append(($0, $1)) },
            dismiss: { dismissals += 1 }
        )
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                try await TypefluxNavigationTestSupport.withWindow(view.environment(\.interfaceStyle, style)
                    .environment(\.colorScheme, dark ? .dark : .light), size: size) { window, host in
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        let field = try #require(TypefluxNavigationTestSupport.searchField(
                            in: host,
                            identifier: "typeflux.spotlight.search"
                        ))
                        window.makeFirstResponder(field)
                        let count = try verifySpotlightKeys(window: window, activated: { activations })
                        try SettingsBehaviorTestSupport.button("Text", in: host).press()
                        #expect(selectedMode == "text")
                        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                                 styleMask: [.titled], backing: .buffered, defer: false)
                        unrelated.isReleasedWhenClosed = false
                        try TypefluxNavigationTestSupport.sendKey(36, to: unrelated)
                        unrelated.close()
                        #expect(activations.count == count)
                        let before = dismissals
                        window.makeKeyAndOrderFront(nil)
                        window.makeFirstResponder(field)
                        try await Task.sleep(for: .milliseconds(100))
                        try TypefluxNavigationTestSupport.sendKey(53, to: window)
                        #expect(dismissals == before + 1)
                        try TypefluxNavigationTestSupport.capture(
                            window,
                            name: "spotlight-\(style.rawValue)-\(dark ? "dark" : "light")"
                        )
                    }
            }
        }
    }

    private func verifyNativeSearch(
        state: TypefluxSearchState,
        item: NSSearchToolbarItem,
        window: NSWindow
    ) async throws {
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        try await SettingsBehaviorTestSupport
            .wait { state.isExpanded && item.searchField.currentEditor() != nil }
        #expect(item.searchField.convert(item.searchField.bounds, to: nil).maxX > window.frame.width - 60)
        let editor = try #require(item.searchField.currentEditor() as? NSTextView)
        editor.insertText(
            "query",
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count)
        )
        item.searchField.validateEditing()
        item.searchField.sendAction(item.searchField.action, to: item.searchField.target)
        try await SettingsBehaviorTestSupport.wait { state.query == "query" }
        try TypefluxNavigationTestSupport.sendKey(53, to: window)
        #expect(state.query.isEmpty && state.isExpanded)
        try TypefluxNavigationTestSupport.sendKey(53, to: window)
        #expect(!state.isExpanded && !state.isFocused)
        try await SettingsBehaviorTestSupport.wait { item.searchField.currentEditor() == nil }
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        state.query = "retained"
        try await Task.sleep(for: .milliseconds(100))
        window.makeFirstResponder(nil)
        try await SettingsBehaviorTestSupport.wait { !state.isFocused }
        #expect(state.isExpanded && state.query == "retained")
        state.query = ""
        #expect(!state.isExpanded)
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        try await Task.sleep(for: .milliseconds(50))
        window.makeFirstResponder(nil)
        try await SettingsBehaviorTestSupport.wait { !state.isExpanded }
    }

    @Test func `search bridge ignores unrelated editing while a toolbar is absent`() async throws {
        let state = TypefluxSearchState()
        try await TypefluxNavigationTestSupport.withWindow(Text("No toolbar")) { window, host in
            let bridge = TypefluxSearchToolbarBridge.BridgeView()
            bridge.state = state
            host.addSubview(bridge)
            #expect(window.toolbar == nil)
            NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: NSTextField())
            NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: nil)
            #expect(!state.isFocused && !state.isExpanded)
            bridge.synchronize()
            bridge.stop()
            bridge.removeFromSuperview()
        }
    }

    private func verifySpotlightKeys(window: NSWindow, activated: () -> [(String, Bool)]) throws -> Int {
        try TypefluxNavigationTestSupport.sendKey(125, to: window)
        try TypefluxNavigationTestSupport.sendKey(36, to: window)
        #expect(activated().last?.0 == "3" && activated().last?.1 == false)
        try TypefluxNavigationTestSupport.sendKey(126, to: window)
        try TypefluxNavigationTestSupport.sendKey(36, modifiers: .command, to: window)
        #expect(activated().last?.0 == "1" && activated().last?.1 == true)
        try TypefluxNavigationTestSupport.sendKey(25, characters: "9", modifiers: .command, to: window)
        #expect(activated().last?.0 == "9")
        let count = activated().count
        try TypefluxNavigationTestSupport.sendKey(19, characters: "2", modifiers: .command, to: window)
        #expect(activated().count == count)

        return count
    }
}
