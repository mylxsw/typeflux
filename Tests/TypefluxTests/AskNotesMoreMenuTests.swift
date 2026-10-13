import AppKit
import Testing
@testable import Typeflux

@Suite("Eager Notes toolbar menu", .serialized, .exclusiveUIState)
@MainActor
struct AskNotesMoreMenuTests {
    @Test func modesExistBeforeOpeningAndDispatchToTheSelectedNote() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let window = try #require(libraries.notes.window)
            let notes = try #require(libraries.notes.model)
            window.setContentSize(AskNotesWindowController.minimumSize)
            try await waitForModes(in: window, enabled: true)
            let menu = try #require(AskNotesToolbarTestSupport.button(in: window)?.menu)
            #expect(!menu.autoenablesItems)
            let modes = menu.items.filter { $0.identifier?.rawValue.hasPrefix("ask.notes.mode.") == true }
            #expect(modes.map(\.title) == [L("ask.notes.preview"), L("ask.notes.mode.edit"), L("ask.notes.mode.split")])
            #expect(modes.allSatisfy { $0.isEnabled && !$0.isHidden && $0.target is AskNotesMoreMenu.Coordinator })
            for mode in [AskNotesViewModel.Mode.split, .edit, .read] {
                try AskNotesToolbarTestSupport.chooseMode(mode, in: window)
                #expect(notes.mode == mode)
                #expect(notes.selectedID == libraries.noteID)
                let current = try #require(AskNotesToolbarTestSupport.button(in: window)?.menu)
                let selected = current.items.first { $0.identifier?.rawValue == "ask.notes.mode." + mode.rawValue }
                #expect(selected?.state == .on)
            }
        }
    }

    @Test func modesStayPresentButDisabledForEmptySelectionPickingAndTrash() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .liquidGlass, dark: true) { libraries in
            let window = try #require(libraries.notes.window)
            let notes = try #require(libraries.notes.model)
            window.setContentSize(AskNotesWindowController.minimumSize)
            try await waitForModes(in: window, enabled: true)
            notes.select(nil)
            try await waitForModes(in: window, enabled: false)
            notes.select(libraries.noteID)
            try await waitForModes(in: window, enabled: true)
            notes.setSelecting(true)
            try await waitForModes(in: window, enabled: false)
            notes.setSelecting(false)
            notes.deleteSelected()
            notes.scope = .trash
            notes.select(libraries.noteID)
            try await waitForModes(in: window, enabled: false)
            try await SettingsBehaviorTestSupport.wait {
                AskNotesToolbarTestSupport.button(in: window)?.menu?.items.contains {
                    $0.identifier?.rawValue == "ask.notes.restore" && $0.isEnabled
                } == true
            }
            try AskNotesToolbarTestSupport.choose("ask.notes.restore", in: window)
            #expect(notes.store.note(id: libraries.noteID)?.isDeleted == false)
        }
    }

    @Test func nativeSecondaryActionsKeepLiveStateAndExportOptions() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let window = try #require(libraries.notes.window)
            let notes = try #require(libraries.notes.model)
            window.setContentSize(AskNotesWindowController.minimumSize)
            try await waitForModes(in: window, enabled: true)
            try AskNotesToolbarTestSupport.choose("ask.notes.pin", in: window)
            #expect(notes.selected?.pinned == true)
            try AskNotesToolbarTestSupport.choose("ask.notes.pin", in: window)
            #expect(notes.selected?.pinned == false)
            let menu = try #require(AskNotesToolbarTestSupport.button(in: window)?.menu)
            let export = try #require(menu.items.first { $0.identifier?.rawValue == "ask.notes.export" }?.submenu)
            #expect(export.items.first?.title == L("ask.notes.export.markdown"))
            let index = try #require(export.items.firstIndex { $0.identifier?.rawValue == "ask.notes.export.original" })
            export.performActionForItem(at: index)
            #expect(notes.exportOptions.original)
            let outlined = notes.showsOutline
            try AskNotesToolbarTestSupport.choose("ask.notes.outline", in: window)
            #expect(notes.showsOutline == !outlined)
        }
    }

    private func waitForModes(in window: NSWindow, enabled: Bool) async throws {
        try await SettingsBehaviorTestSupport.wait {
            let modes = AskNotesToolbarTestSupport.button(in: window)?.menu?.items.filter {
                $0.identifier?.rawValue.hasPrefix("ask.notes.mode.") == true
            } ?? []
            return modes.count == 3 && modes.allSatisfy { $0.isEnabled == enabled }
        }
    }
}
