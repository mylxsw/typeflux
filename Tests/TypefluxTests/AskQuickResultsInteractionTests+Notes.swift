import AppKit
import Foundation
import Testing
@testable import Typeflux

extension AskQuickResultsInteractionTests {
    static let oKey: UInt16 = 31

    private func typeText(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "timed out")
    }

    @Test func anAIPromptIsSavedWhileStreamingThenMovesToAWindow() async throws {
        try await withPasteboard { pasteboard in
            let generator = AskTestTextGenerator()
            generator.pieces = ["**Pol", "ished**", " text"]
            generator.delay = .milliseconds(400)
            let store = makeTestNotes()
            var presented: [AskResultDocument] = []
            let launcher = try await Launcher(text: "") { model in
                model.notes = store
                model.presentResultWindow = { presented.append($0) }
                let plugin = AskPromptPlugin(generator: generator, modelName: { "m" }, savesNotes: true)
                model.plugins = AskPluginSession(plugins: [plugin]) { AskPromptPlugin.keywords }
                model.connectNotes(to: model.plugins)
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await typeText("rw teh text", into: launcher)
            try await waitUntil { if case .ready = model.plugins.phase { true } else { false } }
            try await launcher.press(Self.returnKey)
            try await waitUntil { model.plugins.partial?.body == "**Pol" }
            #expect(model.plugins.partial?.markdown == true)
            try await launcher.press(Self.sKey, .command)
            #expect(model.plugins.savesNoteWhenDone, "⌘S works while the result streams")
            try await waitUntil { model.plugins.output != nil }
            #expect(store.list(AskNoteQuery()).map(\.body) == ["**Polished** text"])
            #expect(model.plugins.output?.starred == true)
            try await launcher.press(8, [.command, .shift])
            #expect(pasteboard.string(forType: .html)?.contains("<strong>Polished</strong>") == true)
            #expect(launcher.dismissed == 0, "⇧⌘C copies rich text and stays")
            generator.pieces = ["Again", " and again"]
            try await launcher.press(15, .command)
            try await waitUntil { model.plugins.partial?.body == "Again" }
            try await launcher.press(Self.oKey, .command)
            #expect(launcher.dismissed == 1, "⌘O closes the launcher")
            let document = try #require(presented.first)
            try await waitUntil { document.state == .done }
            #expect(document.body == "Again and again" && document.noteID == nil)
        }
    }

    @Test func theNoteKeywordListsAndOpensNotes() async throws {
        try await withPasteboard { _ in
            let store = makeTestNotes()
            let note = makeTestNote("Saved answer", body: "Body text")
            store.save(note)
            var windows: [UUID] = []
            let launcher = try await Launcher(text: "") { model in
                model.notes = store
                model.openNoteWindow = { windows.append($0.id) }
                model.plugins = AskPluginSession(plugins: [AskNotesPlugin(store: store)]) { AskNotesPlugin.keywords }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await typeText("note ", into: launcher)
            try await waitUntil { model.plugins.output?.items.first?.title == "Saved answer" }
            try await launcher.press(Self.returnKey)
            #expect(windows == [note.id] && launcher.dismissed == 1)
        }
    }
}
