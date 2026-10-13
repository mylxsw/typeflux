import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
enum AskLibraryTestSupport {
    struct Libraries {
        let notes: AskNotesWindowController
        let words: AskWordBookWindowController
        let settings: SettingsStore
        let noteID: UUID
        let wordKey: String
    }

    static func withLibraries(style: InterfaceStyle, dark: Bool,
                              check: (Libraries) async throws -> Void) async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            settings.interfaceStyle = style
            settings.appearanceMode = dark ? .dark : .light
            let notes = makeTestNotes()
            var note = makeTestNote("Library template",
                                   body: "## Reading\n\nA **solid** content column.\n\n- [ ] Review")
            note.tags = ["design"]
            notes.save(note)
            notes.save(makeTestNote("Search target", body: "A second note"))
            let words = makeTestWordBook()
            let lookup = AskWordBookLookup(headword: wordBookCard.headword, source: "en", target: "zh-Hans",
                                           card: wordBookCard, model: "AI")
            words.record(lookup, at: .now, counts: true)
            words.record(AskWordBookLookup(headword: "plain", source: "en", target: "zh-Hans", translation: "简单"),
                         at: .now.addingTimeInterval(-60), counts: true)
            let noteController = AskNotesWindowController()
            let wordController = AskWordBookWindowController()
            let frameName = "library-tests-\(UUID().uuidString)"
            noteController.frameAutosaveName = frameName + "-notes"
            wordController.frameAutosaveName = frameName + "-words"
            noteController.configure(store: notes, settings: settings, askAI: { _ in }, appearance: {
                NSAppearance(named: dark ? .darkAqua : .aqua)
            })
            wordController.configure(store: words, dictionary: AskTestWordLookup(answer: .card(wordBookCard)),
                                     settings: settings, askAI: { _ in }, modelName: { "AI" })
            noteController.show(selecting: note.id)
            wordController.show(selecting: lookup.key)
            wordController.model?.onDevice = AskTestTranslationEngine(available: false)
            wordController.model?.detector = AskTestLanguageDetector(language: "en")
            defer {
                noteController.window?.close()
                wordController.window?.close()
                NSWindow.removeFrame(usingName: noteController.frameAutosaveName)
                NSWindow.removeFrame(usingName: wordController.frameAutosaveName)
            }
            try await SettingsBehaviorTestSupport.wait {
                noteController.window?.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true
                    && wordController.window?.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true
            }
            try await check(Libraries(notes: noteController, words: wordController, settings: settings,
                                     noteID: note.id, wordKey: lookup.key))
        }
    }

    static func elements(in window: NSWindow) -> [SettingsBehaviorTestSupport.Element] {
        // Native toolbar views own hit-testing; prefer them over SwiftUI's duplicated AX proxies.
        (window.toolbar?.items.compactMap(\.view).flatMap { SettingsBehaviorTestSupport.elements(in: $0) } ?? [])
            + SettingsBehaviorTestSupport.elements(in: window)
    }

    static func action(_ identifier: String, in window: NSWindow) throws -> SettingsBehaviorTestSupport.Element {
        try #require(elements(in: window).first {
            $0.value("accessibilityIdentifier") as? String == "typeflux.toolbar." + identifier
        }, "Missing toolbar action: \(identifier)")
    }

    static func search(_ query: String, in window: NSWindow) async throws -> NSSearchField {
        window.makeKeyAndOrderFront(nil)
        try TypefluxNavigationTestSupport.sendKey(3, characters: "f", modifiers: .command, to: window)
        let item = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
        try await SettingsBehaviorTestSupport.wait { item.searchField.currentEditor() != nil }
        let editor = try #require(item.searchField.currentEditor() as? NSTextView)
        editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        item.searchField.validateEditing()
        item.searchField.sendAction(item.searchField.action, to: item.searchField.target)
        return item.searchField
    }

    static func capture(_ window: NSWindow, name: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_LIBRARY_SNAPSHOTS"] else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent(name + ".png")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let peers = NSApp.windows.filter {
            $0 !== window && $0.isVisible && $0.attachedSheet !== window
                && ($0.delegate is AskNotesWindowController || $0.delegate is AskWordBookWindowController)
        }
        peers.forEach { $0.orderOut(nil) }
        defer { peers.forEach { $0.orderBack(nil) } }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(400))
        window.displayIfNeeded()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: file).count > 1000)
    }
}
