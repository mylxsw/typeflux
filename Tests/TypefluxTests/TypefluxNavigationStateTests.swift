import AppKit
import SwiftUI
import Testing
@testable import TypefluxUI

@Suite(.exclusiveUIState)
@MainActor
struct TypefluxNavigationStateTests {
    @Test func `search expands clears collapses and retains a blurred query`() {
        let state = TypefluxSearchState()
        #expect(!state.isExpanded && !state.isFocused && state.query.isEmpty)
        #expect(!state.escape())
        state.expand()
        #expect(state.isExpanded && state.isFocused)
        state.query = "swift"
        state.focusChanged(false)
        #expect(state.isExpanded && !state.isFocused)
        state.expand()
        #expect(state.escape())
        #expect(state.query.isEmpty && state.isExpanded && state.isFocused)
        #expect(state.escape())
        #expect(!state.isExpanded && !state.isFocused)
        state.expand()
        state.focusChanged(false)
        #expect(!state.isExpanded)
        state.query = "external filter"
        #expect(state.isExpanded)
        state.query = ""
        #expect(!state.isExpanded)
        state.focusChanged(true)
        #expect(state.isExpanded)
        state.query = "x"
        state.clear()
        #expect(state.query.isEmpty && state.isExpanded && state.isFocused)
        let initial = TypefluxSearchState(query: "initial", expanded: false)
        #expect(initial.isExpanded)
        initial.escape()
        #expect(initial.isExpanded && initial.query.isEmpty)
        initial.escape()
        #expect(!initial.isExpanded)
        #expect(TypefluxSearchState(expanded: true).isExpanded)
    }

    @Test func `spotlight selection handles empty disabled removed reordered and extreme input`() {
        let items = [TypefluxSpotlightItem(id: "a", title: "A", subtitle: "One"),
                     TypefluxSpotlightItem(id: "b", title: "B", isEnabled: false),
                     TypefluxSpotlightItem(id: "c", title: "C")]
        var selection = TypefluxSpotlightSelection()
        selection.reconcile(items)
        #expect(selection.selectedID == "a")
        selection.move(1, in: items)
        #expect(selection.selectedID == "c")
        selection.move(Int.max, in: items)
        #expect(selection.selectedID == "c")
        selection.move(Int.min, in: items)
        #expect(selection.selectedID == "a")
        selection.move(0, in: items)
        #expect(selection.selectedID == "a")
        selection.select("missing", in: items)
        selection.select("b", in: items)
        #expect(selection.selectedID == "a")
        selection.select("c", in: items)
        selection.reconcile(Array(items.reversed()))
        #expect(selection.selectedID == "c")
        selection.reconcile(Array(items.prefix(2)))
        #expect(selection.selectedID == "a")
        selection.reconcile([items[1]])
        #expect(selection.selectedID == nil)
        selection.move(1, in: items)
        #expect(selection.selectedID == "a")
        selection.move(-1, in: [])
        #expect(selection.selectedID == nil)
        #expect(selection.quickResult(1, in: items)?.id == "a")
        for number in [Int.min, 0, 2, 4, 10, Int.max] {
            #expect(selection.quickResult(number, in: items) == nil)
        }
        #expect(selection.quickResult(3, in: items)?.id == "c")
        let ten = (1 ... 10).map { TypefluxSpotlightItem(id: String($0), title: String($0)) }
        #expect(selection.quickResult(9, in: ten)?.id == "9")
        #expect(selection.quickResult(10, in: ten) == nil)
    }

    @Test func `spotlight routes all supported keys and leaves other chords untouched`() {
        #expect(TypefluxSpotlightKey.resolve(keyCode: 126, characters: nil, modifiers: []) == .move(-1))
        #expect(TypefluxSpotlightKey.resolve(keyCode: 125, characters: nil, modifiers: .capsLock) == .move(1))
        for code: UInt16 in [36, 76] {
            #expect(TypefluxSpotlightKey
                .resolve(keyCode: code, characters: "\r", modifiers: []) == .activate(plainText: false))
            #expect(TypefluxSpotlightKey
                .resolve(keyCode: code, characters: "\r", modifiers: .command) == .activate(plainText: true))
        }
        #expect(TypefluxSpotlightKey.resolve(keyCode: 53, characters: nil, modifiers: []) == .dismiss)
        for number in 1 ... 9 {
            #expect(TypefluxSpotlightKey
                .resolve(keyCode: 18, characters: String(number), modifiers: .command) == .quick(number))
        }
        for flags: NSEvent.ModifierFlags in [.shift, .option, .control, [.command, .shift], [.command, .option]] {
            #expect(TypefluxSpotlightKey.resolve(keyCode: 36, characters: nil, modifiers: flags) == nil)
            #expect(TypefluxSpotlightKey.resolve(keyCode: 18, characters: "1", modifiers: flags) == nil)
        }
        for text in ["0", "10", "x", "", "f"] {
            #expect(TypefluxSpotlightKey.resolve(keyCode: 18, characters: text, modifiers: .command) == nil)
        }
        #expect(TypefluxSpotlightKey.resolve(keyCode: 18, characters: nil, modifiers: .command) == nil)
        #expect(TypefluxSpotlightKey.resolve(keyCode: 0, characters: "a", modifiers: []) == nil)
    }

    @Test func `component data preserves labels roles and caller actions`() {
        #expect(TypefluxNavigationItem(id: "n", title: "Notes", systemImage: "doc", count: -1).count == 0)
        #expect(TypefluxNavigationItem(id: "n", title: "Notes", systemImage: "doc").count == nil)
        var performed = false
        let action = TypefluxToolbarAction(id: "delete", title: "Delete", systemImage: "trash", role: .destructive,
                                           isEnabled: false) { performed = true }
        let group = TypefluxToolbarGroup(id: "actions", actions: [action])
        #expect(group.actions[0].role == .destructive && !group.actions[0].isEnabled)
        action.perform()
        #expect(performed)
        let confirmation = TypefluxConfirmation(title: "Delete?", message: "Cannot undo", confirmTitle: "Delete",
                                                cancelTitle: "Cancel", role: .destructive)
        #expect(confirmation.role == .destructive && confirmation.cancelTitle == "Cancel")
        #expect(TypefluxSpotlightMode(id: "m", title: "Mode", systemImage: "doc").id == "m")
    }

    @Test func `HUD dismisses after 1 point 5 seconds and cancels replacement`() async throws {
        #expect(TypefluxHUDState.dismissalDelay == .milliseconds(1500))
        let state = TypefluxHUDState()
        let first = TypefluxHUDMessage(title: "Copied")
        let second = TypefluxHUDMessage(title: "Saved")
        state.present(first)
        #expect(state.message == first)
        try await Task.sleep(for: .milliseconds(800))
        state.present(second)
        try await Task.sleep(for: .milliseconds(800))
        #expect(state.message == second)
        try await Task.sleep(for: .milliseconds(800))
        #expect(state.message == nil)
        state.present(first)
        state.dismiss()
        #expect(state.message == nil)
        let failedClock = TypefluxHUDState(sleep: { _ in throw CancellationError() })
        failedClock.present(first)
        await Task.yield()
        #expect(failedClock.message == first)
        failedClock.dismiss()
        var ephemeral: TypefluxHUDState? = TypefluxHUDState()
        weak var released = ephemeral
        ephemeral?.present(second)
        ephemeral = nil
        #expect(released == nil)
    }
}
