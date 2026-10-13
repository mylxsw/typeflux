import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Library design fidelity", .exclusiveUIState)
@MainActor
struct AskLibraryDesignFidelityTests {
    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func titleActionsNewAndSearchKeepTheirOrder(style: InterfaceStyle, dark: Bool) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: dark) { libraries in
            for (window, prefix, actions) in [
                (try #require(libraries.notes.window), "notes", ["copy", "pin", "share", "delete"]),
                (try #require(libraries.words.window), "wordBook", ["star", "copy", "delete"])
            ] {
                window.setContentSize(NSSize(width: 1100, height: 800))
                try await SettingsBehaviorTestSupport.wait {
                    actions.allSatisfy { action in
                        AskLibraryTestSupport.elements(in: window).contains {
                            $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar.\(prefix).\(action)"
                                && inside($0.frame, window: window)
                        }
                    }
                }
                let title = try #require(AskLibraryTestSupport.elements(in: window).first {
                    $0.value("accessibilityIdentifier") as? String == "typeflux.window.title"
                })
                let new = try AskLibraryTestSupport.action(prefix + ".new", in: window)
                let frames = try actions.map { try AskLibraryTestSupport.action(prefix + "." + $0, in: window).frame }
                let first = try #require(frames.first)
                let last = try #require(frames.last)
                #expect(title.frame.minX < first.minX)
                for (left, right) in zip(frames, frames.dropFirst()) { #expect(left.maxX <= right.minX + 1) }
                #expect(last.maxX <= new.frame.minX + 1)
                let search = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
                #expect(new.frame.maxX <= screenFrame(search.searchField, in: window).minX + 1)
                #expect(inside(new.frame, window: window))
            }
        }
    }

    @Test(arguments: InterfaceStyle.allCases, [false, true])
    func readTitleRowsAndPronunciationUseCompactReadableContent(style: InterfaceStyle, dark: Bool) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: dark) { libraries in
            let noteWindow = try #require(libraries.notes.window)
            let wordWindow = try #require(libraries.words.window)
            let notes = try #require(libraries.notes.model)
            let words = try #require(libraries.words.model)
            for window in [noteWindow, wordWindow] { window.setContentSize(NSSize(width: 1320, height: 800)) }
            try await SettingsBehaviorTestSupport.wait {
                AskLibraryTestSupport.elements(in: noteWindow).contains {
                    $0.value("accessibilityIdentifier") as? String == "ask.notes.title"
                }
            }
            let title = try #require(AskLibraryTestSupport.elements(in: noteWindow).first {
                $0.value("accessibilityIdentifier") as? String == "ask.notes.title"
            })
            #expect(title.role != NSAccessibility.Role.textField.rawValue,
                    "A reading title cannot retain a field editor's selected text")
            #expect(title.role != NSAccessibility.Role.textArea.rawValue)
            for (window, identifier) in [(noteWindow, "ask.notes.row"), (wordWindow, "ask.wordBook.row")] {
                let rows = AskLibraryTestSupport.elements(in: window).filter {
                    $0.value("accessibilityIdentifier") as? String == identifier
                }
                #expect(rows.count >= 2)
                for row in rows {
                    #expect(abs(row.frame.height - (style == .classic ? 28 : 32)) <= 1)
                }
            }
            let content = try #require(noteWindow.contentView)
            let reader = try #require(SettingsBehaviorTestSupport.nativeViews(in: content)
                .compactMap { $0 as? AskNoteReaderText.ReaderView }.first)
            #expect(reader.frame.width <= 680 && reader.frame.width >= 300)
            let row = try #require(AskLibraryTestSupport.elements(in: noteWindow).first {
                $0.value("accessibilityIdentifier") as? String == "ask.notes.row"
            })
            let center = (row.frame.maxX + noteWindow.frame.maxX) / 2
            #expect(abs(screenFrame(reader, in: noteWindow).midX - center) < 20)
            let body = (reader.string as NSString).range(of: "A solid content column.")
            try #require(body.location != NSNotFound)
            let font = try #require(reader.textStorage?.attribute(.font, at: body.location,
                                                                  effectiveRange: nil) as? NSFont)
            #expect(font.pointSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
            var spoken: String?
            words.speakText = { text, _ in spoken = text }
            let sound = try #require(AskLibraryTestSupport.elements(in: wordWindow).first {
                $0.value("accessibilityIdentifier") as? String == "ask.wordBook.pronunciation"
            })
            #expect(sound.frame.height <= TypefluxControlHeight.button.value(for: style) + 2)
            try sound.press()
            try await SettingsBehaviorTestSupport.wait { spoken != nil }
            #expect(spoken == words.displayed?.headword)
            notes.setMode(.edit)
            try await SettingsBehaviorTestSupport.wait {
                AskLibraryTestSupport.elements(in: noteWindow).contains {
                    $0.value("accessibilityIdentifier") as? String == "ask.notes.title"
                        && [NSAccessibility.Role.textField.rawValue, NSAccessibility.Role.textArea.rawValue]
                            .contains($0.role)
                }
            }
            notes.setMode(.read)
        }
    }

    @Test(arguments: InterfaceStyle.allCases)
    func minimumWindowMenusPreserveFiltersAndCreation(style: InterfaceStyle) async throws {
        try await AskLibraryTestSupport.withLibraries(style: style, dark: false) { libraries in
            let noteWindow = try #require(libraries.notes.window)
            let wordWindow = try #require(libraries.words.window)
            let notes = try #require(libraries.notes.model)
            noteWindow.setContentSize(AskNotesWindowController.minimumSize)
            wordWindow.setContentSize(AskWordBookWindowController.minimumSize)
            try await SettingsBehaviorTestSupport.wait { AskNotesToolbarTestSupport.button(in: noteWindow) != nil }
            let menu = try #require(AskNotesToolbarTestSupport.button(in: noteWindow)?.menu)
            let filter = try #require(menu.items.first { $0.identifier?.rawValue == "ask.notes.filter" }?.submenu)
            let trash = try #require(filter.items.first { $0.title == L("ask.notes.shelf.trash") })
            #expect(NSApp.sendAction(try #require(trash.action), to: trash.target, from: trash))
            #expect(notes.inTrash)
            notes.scope = .all
            let before = notes.notes.count
            noteWindow.makeKeyAndOrderFront(nil)
            try AskLibraryTestSupport.action("notes.new", in: noteWindow).press()
            try await SettingsBehaviorTestSupport.wait { notes.notes.count == before + 1 && notes.editing }
            #expect(notes.notes.count == before + 1 && notes.editing)
            #expect(notes.finishEditing())
            wordWindow.makeKeyAndOrderFront(nil)
            try AskLibraryTestSupport.action("wordBook.new", in: wordWindow).press()
            try await SettingsBehaviorTestSupport.wait { wordWindow.attachedSheet != nil }
            let sheet = try #require(wordWindow.attachedSheet)
            try SettingsBehaviorTestSupport.button(L("common.cancel"), in: sheet).press()
            try await SettingsBehaviorTestSupport.wait { wordWindow.attachedSheet == nil }
            for (window, prefix, query) in [(noteWindow, "notes", "Reading"), (wordWindow, "wordBook", "plain")] {
                _ = try await AskLibraryTestSupport.search(query, in: window)
                try await SettingsBehaviorTestSupport.wait {
                    AskLibraryTestSupport.elements(in: window).contains {
                        $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar." + prefix + ".new"
                            && inside($0.frame, window: window)
                    }
                }
                #expect(window.isVisible)
            }
        }
    }

    private func inside(_ frame: NSRect, window: NSWindow) -> Bool {
        frame.width >= 20 && frame.height >= 20 && frame.minX >= window.frame.minX - 1
            && frame.maxX <= window.frame.maxX + 1 && frame.minY >= window.frame.minY - 1
            && frame.maxY <= window.frame.maxY + 1
    }

    @Test func sharingUsesTheCurrentDraftAndRejectsUnavailableSelections() async throws {
        try await AskLibraryTestSupport.withLibraries(style: .classic, dark: false) { libraries in
            let notes = try #require(libraries.notes.model)
            let note = try #require(notes.selected)
            #expect(notes.sharingText == note.title + "\n\n" + note.body)
            notes.autosaveDelay = .seconds(60)
            notes.beginEditing()
            notes.draftBody = "Current draft"
            notes.stageTitle("Current title", id: note.id)
            #expect(notes.sharingText == "Current title\n\nCurrent draft")
            notes.setSelecting(true)
            #expect(notes.sharingText == nil)
            notes.setSelecting(false)
            notes.select(nil)
            #expect(notes.sharingText == nil)
            notes.select(note.id)
            notes.deleteSelected()
            notes.scope = .trash
            notes.select(note.id)
            #expect(notes.sharingText == nil)
        }
    }

    private func screenFrame(_ view: NSView, in window: NSWindow) -> NSRect {
        window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
