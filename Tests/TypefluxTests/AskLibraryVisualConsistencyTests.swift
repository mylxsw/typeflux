import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Native library windows", .exclusiveUIState)
@MainActor
struct AskLibraryVisualConsistencyTests {
    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func toolbarActionsAndSearchWork(style: InterfaceStyle, dark: Bool) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: dark) { libraries in
            let noteWindow = try #require(libraries.notes.window)
            let wordWindow = try #require(libraries.words.window)
            let notes = try #require(libraries.notes.model)
            let words = try #require(libraries.words.model)
            for window in [noteWindow, wordWindow] {
                #expect(window.isOpaque)
                #expect(window.backgroundColor == .windowBackgroundColor)
                #expect(window.toolbarStyle == .unified)
            }
            var copiedNote: String?
            notes.copy = { copiedNote = $0 }
            try AskLibraryTestSupport.action("notes.copy", in: noteWindow).press()
            #expect(copiedNote == notes.selected?.body)
            try AskLibraryTestSupport.action("notes.pin", in: noteWindow).press()
            try await SettingsBehaviorTestSupport.wait { notes.selected?.pinned == true }
            try AskLibraryTestSupport.action("notes.delete", in: noteWindow).press()
            try await SettingsBehaviorTestSupport.wait { notes.store.note(id: libraries.noteID)?.isDeleted == true }
            notes.scope = .trash
            notes.select(libraries.noteID)
            try await SettingsBehaviorTestSupport.wait {
                AskLibraryTestSupport.elements(in: noteWindow).contains {
                    $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar.notes.restore"
                }
            }
            try AskLibraryTestSupport.action("notes.restore", in: noteWindow).press()
            try await SettingsBehaviorTestSupport.wait { notes.store.note(id: libraries.noteID)?.isDeleted == false }
            notes.scope = .all
            let noteSearch = try await AskLibraryTestSupport.search("Search target", in: noteWindow)
            try await SettingsBehaviorTestSupport.wait { notes.notes.count == 1 && notes.searchText == "Search target" }
            #expect(noteSearch.stringValue == notes.searchText)
            try TypefluxNavigationTestSupport.sendKey(53, to: noteWindow)
            try await SettingsBehaviorTestSupport.wait { notes.searchText.isEmpty }
            #expect(noteWindow.isVisible, "first Escape clears search without closing the library")

            try await checkWordActionsAndSearch(words, window: wordWindow, key: libraries.wordKey)
        }
    }

    private func checkWordActionsAndSearch(_ words: AskWordBookViewModel, window wordWindow: NSWindow,
                                           key: String) async throws {
        var copiedWord: String?
        words.copy = { copiedWord = $0 }
        wordWindow.makeKeyAndOrderFront(nil)
        try AskLibraryTestSupport.action("wordBook.copy", in: wordWindow).press()
        #expect(copiedWord?.isEmpty == false)
        try AskLibraryTestSupport.action("wordBook.star", in: wordWindow).press()
        try await SettingsBehaviorTestSupport.wait {
            words.displayed?.isStarred == true && words.store.entry(forKey: key)?.isStarred == true
        }
        try AskLibraryTestSupport.action("wordBook.delete", in: wordWindow).press()
        try await SettingsBehaviorTestSupport.wait { words.store.entry(forKey: key) == nil }
        words.undoDelete()
        #expect(words.store.entry(forKey: key)?.isStarred == true)
        let wordSearch = try await AskLibraryTestSupport.search("plain", in: wordWindow)
        try await SettingsBehaviorTestSupport.wait { words.entries.count == 1 && words.filterText == "plain" }
        #expect(wordSearch.stringValue == words.filterText)
        try TypefluxNavigationTestSupport.sendKey(53, to: wordWindow)
        try await SettingsBehaviorTestSupport.wait { words.filterText.isEmpty }
    }

    @Test func toolbarCallbacksReadTheCurrentWordBeforeRedrawing() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let words = try #require(libraries.words.model)
            // Keep the same rendered callbacks throughout, as with consecutive native toolbar clicks.
            let actions = AskWordBookView(model: words) {}.toolbarGroups.flatMap(\.actions)
            let star = try #require(actions.first { $0.id == "wordBook.star" })
            let delete = try #require(actions.first { $0.id == "wordBook.delete" })
            star.perform()
            #expect(words.store.entry(forKey: libraries.wordKey)?.isStarred == true)
            star.perform()
            #expect(words.store.entry(forKey: libraries.wordKey)?.isStarred == false)
            star.perform()
            delete.perform()
            words.undoDelete()
            #expect(words.store.entry(forKey: libraries.wordKey)?.isStarred == true)
            let plain = try #require(words.entries.first { $0.headword == "plain" })
            words.selectedKey = plain.key
            var copied: String?
            words.copy = { copied = $0 }
            try #require(actions.first { $0.id == "wordBook.copy" }).perform()
            #expect(copied == plain.lookup.firstMeaning)
            star.perform()
            #expect(words.store.entry(forKey: plain.key)?.isStarred == true)
            delete.perform()
            #expect(words.store.entry(forKey: plain.key) == nil)
            #expect(words.store.entry(forKey: libraries.wordKey)?.isStarred == true)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func sidebarToggleAndResizePreserveSelection(style: InterfaceStyle) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: false) { libraries in
            for window in [try #require(libraries.notes.window), try #require(libraries.words.window)] {
                for width in [1320, 900, 720, 1320] {
                    window.setContentSize(NSSize(width: width, height: 620))
                    try await Task.sleep(for: .milliseconds(150))
                    #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
                }
                try TypefluxNavigationTestSupport.toggleSidebar(in: window)
                try TypefluxNavigationTestSupport.toggleSidebar(in: window)
            }
            #expect(libraries.notes.model?.selectedID == libraries.noteID)
            #expect(libraries.words.model?.selectedKey == libraries.wordKey)
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func minimumNotesWindowKeepsCopyAndTheActionsMenuInsideTheWindow(style: InterfaceStyle, dark: Bool) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: dark) { libraries in
            let window = try #require(libraries.notes.window)
            let notes = try #require(libraries.notes.model)
            window.setContentSize(AskNotesWindowController.minimumSize)
            window.makeKeyAndOrderFront(nil)
            try await SettingsBehaviorTestSupport.wait {
                let elements = AskLibraryTestSupport.elements(in: window)
                let menu = elements.first { $0.value("accessibilityIdentifier") as? String == "ask.notes.more" }
                let copy = elements.first {
                    $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar.notes.copy"
                }
                return copy.map { insideWindow($0.frame, window: window) } == true
                    && menu.map { insideWindow($0.frame, window: window) } == true
                    && !elements.contains {
                        $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar.notes.pin"
                    }
            }
            var copied: String?
            notes.copy = { copied = $0 }
            let expectedBody = try #require(notes.selected?.body)
            let copy = try AskLibraryTestSupport.action("notes.copy", in: window)
            try copy.press()
            try await SettingsBehaviorTestSupport.wait { copied == expectedBody }
            #expect(copied?.isEmpty == false)
            for mode in [AskNotesViewModel.Mode.split, .edit, .read] {
                try AskNotesToolbarTestSupport.chooseMode(mode, in: window)
                try await SettingsBehaviorTestSupport.wait { notes.mode == mode }
                #expect(notes.mode == mode, "each native mode action remains reachable at minimum width")
                try await Task.sleep(for: .milliseconds(200))
            }
            _ = try await AskLibraryTestSupport.search("Reading", in: window)
            try await SettingsBehaviorTestSupport.wait { notes.searchText == "Reading" }
            let searchingCopy = try AskLibraryTestSupport.action("notes.copy", in: window)
            #expect(insideWindow(searchingCopy.frame, window: window), "expanded search cannot displace copy")
        }
    }

    private func insideWindow(_ frame: NSRect, window: NSWindow) -> Bool {
        frame.width >= 20 && frame.height >= 20
            && frame.minX >= window.frame.minX - 1 && frame.maxX <= window.frame.maxX + 1
            && frame.minY >= window.frame.minY - 1 && frame.maxY <= window.frame.maxY + 1
    }

    @Test func newNoteToolbarActionCreatesAnEditablePersistedNote() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let window = try #require(libraries.notes.window)
            let model = try #require(libraries.notes.model)
            let before = model.notes.count
            window.makeKeyAndOrderFront(nil)
            try AskLibraryTestSupport.action("notes.new", in: window).press()
            try await SettingsBehaviorTestSupport.wait { model.notes.count == before + 1 && model.editing }
            let id = try #require(model.selectedID)
            model.draftBody = "Written through the new note action"
            #expect(model.finishEditing())
            #expect(model.store.note(id: id)?.body == "Written through the new note action")
        }
    }

    @Test func lookupSheetCreatesAWordThroughTheNativeDefaultAction() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let window = try #require(libraries.words.window)
            let model = try #require(libraries.words.model)
            let card = AskWordCard(headword: "newword", senses: [.init(pos: "n.", meanings: ["new meaning"])])
            model.dictionary = AskTestWordLookup(answer: .card(card))
            window.makeKeyAndOrderFront(nil)
            try AskLibraryTestSupport.action("wordBook.new", in: window).press()
            try await SettingsBehaviorTestSupport.wait { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            model.lookupText = "newword"
            try await SettingsBehaviorTestSupport.wait {
                SettingsBehaviorTestSupport.elements(in: sheet).contains { $0.text == "newword" }
            }
            try SettingsBehaviorTestSupport.button(L("ask.wordBook.lookup.open"), in: sheet).press()
            try await SettingsBehaviorTestSupport.wait { model.displayed?.headword == "newword" }
            let key = try #require(model.displayed?.key)
            #expect(model.store.entry(forKey: key) != nil)
        }
    }
}
