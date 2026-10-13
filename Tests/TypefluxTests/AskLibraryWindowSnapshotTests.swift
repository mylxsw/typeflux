import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Run on the acceptance Mac; captures include native toolbar and WindowServer glass.
@Suite("Library window snapshot matrix", .exclusiveUIState)
@MainActor
struct AskLibraryWindowSnapshotTests {
    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func libraryStates(style: InterfaceStyle, dark: Bool) async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_LIBRARY_SNAPSHOTS"] != nil else { return }
        TypefluxTestApplicationEnvironment.prepare()
        try await AskLibraryTestSupport.withLibraries(style: style, dark: dark) { libraries in
            let noteWindow = try #require(libraries.notes.window)
            let wordWindow = try #require(libraries.words.window)
            let notes = try #require(libraries.notes.model)
            let words = try #require(libraries.words.model)
            let word = try #require(words.displayed?.headword)
            let suffix = "\(style.rawValue)-\(dark ? "dark" : "light")"
            for (window, name) in [(noteWindow, "notes"), (wordWindow, "wordbook")] {
                window.setContentSize(NSSize(width: 1100, height: 800))
                window.setFrameOrigin(NSPoint(x: 40, y: 40))
                try await AskLibraryTestSupport.capture(window, name: "\(name)-read-\(suffix)")
                _ = try await AskLibraryTestSupport.search(name == "notes" ? "Reading" : word,
                                                          in: window)
                try await AskLibraryTestSupport.capture(window, name: "\(name)-search-\(suffix)")
                try TypefluxNavigationTestSupport.sendKey(53, to: window)
                try TypefluxNavigationTestSupport.sendKey(53, to: window)
                window.setContentSize(NSSize(width: 720, height: 600))
                try await AskLibraryTestSupport.capture(window, name: "\(name)-compact-\(suffix)")
                window.setContentSize(NSSize(width: 1100, height: 800))
            }
            try await captureNoteStates(notes, window: noteWindow, id: libraries.noteID, suffix: suffix)
            words.toggleStar(try #require(words.displayed))
            words.shelf = .starred
            try await AskLibraryTestSupport.capture(wordWindow, name: "wordbook-favourite-\(suffix)")
            wordWindow.makeKeyAndOrderFront(nil)
            try AskLibraryTestSupport.action("wordBook.new", in: wordWindow).press()
            try await SettingsBehaviorTestSupport.wait { wordWindow.attachedSheet != nil }
            words.lookupText = "new word"
            try await AskLibraryTestSupport.capture(wordWindow, name: "wordbook-new-\(suffix)")
            let sheet = try #require(wordWindow.attachedSheet)
            try await AskLibraryTestSupport.capture(sheet, name: "wordbook-lookup-sheet-\(suffix)")
            try SettingsBehaviorTestSupport.button(L("common.cancel"), in: sheet).press()
            try await SettingsBehaviorTestSupport.wait { wordWindow.attachedSheet == nil }
            notes.searchText = "no matching note"
            words.filterText = "no matching word"
            try await AskLibraryTestSupport.capture(noteWindow, name: "notes-empty-\(suffix)")
            try await AskLibraryTestSupport.capture(wordWindow, name: "wordbook-empty-\(suffix)")
        }
    }

    private func captureNoteStates(_ notes: AskNotesViewModel, window noteWindow: NSWindow,
                                   id: UUID, suffix: String) async throws {
        notes.select(id)
        notes.setMode(.edit)
        try await AskLibraryTestSupport.capture(noteWindow, name: "notes-edit-\(suffix)")
        notes.setMode(.split)
        try await AskLibraryTestSupport.capture(noteWindow, name: "notes-split-\(suffix)")
        notes.setMode(.read)
        notes.deleteSelected()
        notes.scope = .trash
        notes.select(id)
        try await AskLibraryTestSupport.capture(noteWindow, name: "notes-trash-\(suffix)")
        notes.restoreFromTrash()
        notes.scope = .all
        notes.createNote(title: "New note")
        try await AskLibraryTestSupport.capture(noteWindow, name: "notes-new-\(suffix)")
        notes.setMode(.read)
        notes.setSelecting(true)
        notes.pickAll()
        try await AskLibraryTestSupport.capture(noteWindow, name: "notes-selection-\(suffix)")
        notes.setSelecting(false)
    }

    @Test(arguments: [false, true])
    func accessibilityFallbacks(dark: Bool) async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_LIBRARY_SNAPSHOTS"] != nil else { return }
        try await AskLibraryTestSupport.withLibraries(style: .liquidGlass, dark: dark) { libraries in
            let notes = try #require(libraries.notes.model)
            let words = try #require(libraries.words.model)
            for reduced in [true, false] {
                let options = TypefluxAccessibilityOptions(reduceTransparency: reduced, increasedContrast: !reduced)
                let noteWindow = try #require(libraries.notes.window)
                let wordWindow = try #require(libraries.words.window)
                let noteHost = NSHostingView(rootView: AskNotesView(model: notes) {}
                    .environment(\.interfaceStyle, .liquidGlass).environment(\.typefluxAccessibilityOptions, options))
                let wordHost = NSHostingView(rootView: AskWordBookView(model: words) {}
                    .environment(\.interfaceStyle, .liquidGlass).environment(\.typefluxAccessibilityOptions, options))
                noteHost.sizingOptions = []
                wordHost.sizingOptions = []
                noteWindow.contentView = noteHost
                wordWindow.contentView = wordHost
                for (window, name) in [(noteWindow, "notes"), (wordWindow, "wordbook")] {
                    window.appearance = NSAppearance(named: reduced ? (dark ? .darkAqua : .aqua)
                        : (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua))
                    let suffix = "\(reduced ? "reduce-transparency" : "increase-contrast")-\(dark ? "dark" : "light")"
                    try await AskLibraryTestSupport.capture(window, name: "\(name)-\(suffix)")
                }
            }
        }
    }
}
