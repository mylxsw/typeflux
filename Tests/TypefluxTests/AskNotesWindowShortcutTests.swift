import AppKit
import Testing
@testable import Typeflux

@Suite("Notes window mode commands", .serialized, .exclusiveUIState)
@MainActor
struct AskNotesWindowShortcutTests {
    @Test(arguments: InterfaceStyle.allCases)
    func modeCommandsWorkBeforeOpeningTheCompactMenu(style: InterfaceStyle) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: false) { libraries in
            let window = try #require(libraries.notes.window as? AskNotesWindow)
            let notes = try #require(libraries.notes.model)
            window.setContentSize(AskNotesWindowController.minimumSize)
            window.makeKeyAndOrderFront(nil)
            #expect(window.notesModel === notes)
            for expected in [AskNotesViewModel.Mode.split, .read] {
                try TypefluxNavigationTestSupport.sendKey(14, characters: "e", modifiers: [.command, .option],
                                                          to: window, keyEquivalent: true)
                #expect(notes.mode == expected)
            }
            for expected in [AskNotesViewModel.Mode.edit, .read] {
                try TypefluxNavigationTestSupport.sendKey(14, characters: "e", modifiers: .command,
                                                          to: window, keyEquivalent: true)
                #expect(notes.mode == expected)
            }
        }
    }

    @Test func commandsRespectSelectionPickingAndClosedWindowScope() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let window = try #require(libraries.notes.window as? AskNotesWindow)
            let notes = try #require(libraries.notes.model)
            window.makeKeyAndOrderFront(nil)
            notes.select(nil)
            try splitKey(in: window)
            #expect(notes.mode == .read)
            notes.select(libraries.noteID)
            notes.setSelecting(true)
            try splitKey(in: window)
            #expect(notes.mode == .read)
            notes.setSelecting(false)
            let words = try #require(libraries.words.window)
            try splitKey(in: words)
            #expect(notes.mode == .read, "a different library window cannot change Notes mode")
            window.close()
            try splitKey(in: window)
            #expect(notes.mode == .read, "a retained closed window cannot dispatch mode commands")
        }
    }

    private func splitKey(in window: NSWindow) throws {
        try TypefluxNavigationTestSupport.sendKey(14, characters: "e", modifiers: [.command, .option],
                                                  to: window, keyEquivalent: true)
    }
}
