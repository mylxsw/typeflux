import AppKit
import Foundation
import Testing
@testable import Typeflux

func makeTestNotes() -> SQLiteAskNoteStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("notes-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("notes.sqlite")
    let store = SQLiteAskNoteStore(url: url)
    store.notificationCenter = NotificationCenter()
    return store
}

func makeTestNote(_ title: String = "Explain · Comparative advantage", body: String = "**Bold** text",
                  command: String = "Explain", input: String = "Comparative advantage", tags: [String] = [],
                  pinned: Bool = false, at seconds: TimeInterval = 1000) -> AskNote {
    AskNote(title: title, body: body, command: command, keyword: "ex", input: input, model: "gpt-test",
            sourceApp: "Notes", sourceBundleID: "com.apple.Notes", tags: tags, pinned: pinned,
            createdAt: Date(timeIntervalSince1970: seconds), updatedAt: Date(timeIntervalSince1970: seconds))
}

@Suite(.exclusiveUIState)
@MainActor
struct AskNotesStoreTests {
    @Test func `a draft becomes A note titled after its command and input`() {
        let date = Date(timeIntervalSince1970: 50)
        let draft = AskNoteDraft(
            command: "Explain",
            keyword: "ex",
            input: "  Comparative\n advantage in   trade theory ok ",
            body: "Body",
            model: "m",
            sourceApp: "Safari",
            sourceBundleID: "com.apple.Safari"
        )
        let note = AskNote(draft: draft, at: date)
        #expect(note.title == "Explain · Comparative advantage in…")
        #expect(note.body == "Body" && note.command == "Explain" && note.keyword == "ex" && note.model == "m")
        #expect(note.sourceApp == "Safari" && note.sourceBundleID == "com.apple.Safari")
        #expect(note.createdAt == date && note.updatedAt == date && !note.isEdited && !note.pinned && note.tags.isEmpty)
        #expect(AskNote.title(command: "Sum", input: "", body: "# Heading\n\nText") == "Sum · Heading Text")
        #expect(AskNote.title(command: "", input: "short") == "short")
        #expect(AskNote.title(command: "Only", input: "") == "Only")
    }

    @Test func `plain text drops markdown for excerpts`() {
        let markdown = """
        # Title
        > quoted **bold** and `code`
        - item [link](https://x.y)
        1. first

        | a | b |
        |---|---|
        ```swift
        let x = 1
        ```
        """
        #expect(AskNote.plainText(markdown) == "Title\nquoted bold and code\nitem link\nfirst\na  b\nlet x = 1")
        #expect(makeTestNote(body: "## Hi\n\n*there*").excerpt == "Hi there")
        #expect(AskNote.normalizedTag("  ##work ") == "work")
        #expect(AskNote.normalizedTag(" # ") == nil)
        #expect(AskNote.normalizedTag(String(repeating: "a", count: 60))?.count == 40)
    }

    @Test func `saves lists and finds notes`() throws {
        let store = makeTestNotes()
        let old = makeTestNote("Old", body: "比较优势与机会成本", tags: ["读书"], at: 100)
        let pinned = makeTestNote(
            "Pinned",
            body: "pinned",
            command: "Summarize",
            tags: ["work", "读书"],
            pinned: true,
            at: 50
        )
        var newer = makeTestNote("Newer", body: "100% sure_thing", input: "rag", at: 300)
        newer.createdAt = Date(timeIntervalSince1970: 10)
        #expect(store.save(old) && store.save(pinned) && store.save(newer))
        #expect(store.list(AskNoteQuery()).map(\.title) == ["Pinned", "Newer", "Old"], "pinned first, then newest")
        #expect(store.list(AskNoteQuery(sort: .created)).map(\.title) == ["Pinned", "Old", "Newer"])
        #expect(store.list(AskNoteQuery(scope: .pinned)).map(\.title) == ["Pinned"])
        #expect(store.list(AskNoteQuery(scope: .command("Summarize"))).map(\.title) == ["Pinned"])
        #expect(store.list(AskNoteQuery(scope: .tag("读书"))).map(\.title) == ["Pinned", "Old"])
        #expect(store.list(AskNoteQuery(text: "机会成本")).map(\.title) == ["Old"], "Chinese matches inside text")
        #expect(store.list(AskNoteQuery(text: "RAG")).map(\.title) == ["Newer"], "inputs match, case-insensitively")
        #expect(store.list(AskNoteQuery(text: "100%")).map(\.title) == ["Newer"])
        #expect(store.list(AskNoteQuery(text: "s_r")).isEmpty, "LIKE wildcards are literal")
        #expect(store.list(AskNoteQuery(limit: 1, offset: 1)).map(\.title) == ["Newer"])
        #expect(store.count(.all) == 3 && store.count(.pinned) == 1 && store.count(.tag("work")) == 1)
        #expect(store.commands() == [
            AskNoteFacet(name: "Explain", count: 2),
            AskNoteFacet(name: "Summarize", count: 1)
        ])
        #expect(store.tags() == [AskNoteFacet(name: "读书", count: 2), AskNoteFacet(name: "work", count: 1)])
        let read = try #require(store.note(id: old.id))
        #expect(read == old, "every field round-trips")
    }

    @Test func `updates deletes and restores`() async throws {
        let store = makeTestNotes()
        let center = NotificationCenter()
        store.notificationCenter = center
        var changes = 0
        let observer = center.addObserver(forName: .askNotesDidChange, object: nil, queue: nil) { _ in changes += 1 }
        defer { center.removeObserver(observer) }
        var note = makeTestNote()
        store.save(note)
        note.body = "Edited"
        note.editedAt = Date(timeIntervalSince1970: 2000)
        store.save(note)
        #expect(store.note(id: note.id)?.body == "Edited" && store.note(id: note.id)?.isEdited == true)
        #expect(store.count(.all) == 1, "saving again replaces")
        store.delete(ids: [note.id])
        #expect(store.note(id: note.id) == nil)
        store.restore([note])
        #expect(store.note(id: note.id) == note)
        store.delete(ids: [])
        store.restore([])
        #expect(AskNoteQuery.Sort.allCases == [.updated, .created])
        for _ in 0 ..< 100 where changes < 4 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(changes == 4)
    }

    @Test func `a broken database reads as empty`() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        // A directory where the database should be cannot be opened.
        let store = SQLiteAskNoteStore(url: file)
        store.notificationCenter = NotificationCenter()
        #expect(!store.save(makeTestNote()))
        #expect(store.list(AskNoteQuery()).isEmpty && store.count(.all) == 0 && store.tags().isEmpty)
        #expect(store.note(id: UUID()) == nil)
        #expect(SQLiteAskNoteStore.defaultURL().lastPathComponent == "notes.sqlite")
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct AskNoteExportTests {
    @Test func `exports markdown with front matter`() {
        var note = makeTestNote("Say \"hi\": now", body: "\n# Body\n", tags: ["a", "b c"])
        note.sourceApp = nil
        let text = AskNoteExporter.markdown(note)
        #expect(text.hasPrefix("---\ntitle: \"Say \\\"hi\\\": now\"\ncommand: \"Explain\"\nmodel: \"gpt-test\"\n"))
        #expect(text
            .contains(
                "tags: [\"a\", \"b c\"]\ncreated: 1970-01-01T00:16:40Z\nupdated: 1970-01-01T00:16:40Z\n---\n\n# Body\n"
            ))
        #expect(!text.contains("source:"))
        note.sourceApp = "Mail"
        note.model = nil
        #expect(AskNoteExporter.markdown(note).contains("source: \"Mail\"") && !AskNoteExporter.markdown(note)
            .contains("model:"))
        #expect(AskNoteExporter.fileName(makeTestNote("a/b: c?")) == "a b  c.md")
        #expect(AskNoteExporter.fileName(makeTestNote("...")) == L("ask.notes.untitled") + ".md")
        #expect(AskNoteExporter.fileName(makeTestNote(String(repeating: "x", count: 100))).count == 83)
    }

    @Test func `copies markdown as HTMLRTF and text`() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ask.notes.rich.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        AskRichCopy.copy("# Title\n\n**bold** item", to: pasteboard)
        let html = try #require(pasteboard.string(forType: .html))
        #expect(html.contains("<h1>Title</h1>") && html.contains("<strong>bold</strong>"))
        #expect(pasteboard.data(forType: .rtf).map { String(decoding: $0, as: UTF8.self).hasPrefix("{\\rtf") } == true)
        #expect(pasteboard.string(forType: .string) == "# Title\n\n**bold** item")
    }
}

@Suite(.exclusiveUIState)
@MainActor
struct AskNotesPluginTests {
    private func request(_ text: String = "", origin: AskPluginRequest.Origin = .argument) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskNotesPlugin.keywords[0], options: [:],
                         interfaceLanguage: .english)
    }

    @Test func `describes itself`() async {
        let plugin = AskNotesPlugin()
        #expect(plugin.id == "notes" && plugin.title == L("ask.notes.title") && plugin.symbol == "note.text")
        #expect(plugin.defaultKeywords.map(\.keyword) == ["nb", "笔记"])
        #expect(plugin.runsWithoutInput && !plugin.usesSelectionInput && plugin.entersOnReturn)
        #expect(plugin.placeholder(selectionLines: 2) == L("ask.notes.placeholder"))
        #expect(plugin.chipDetail(for: AskNotesPlugin.keywords[0], language: .english) == nil)
        let plan = await plugin.plan(request())
        #expect(plan.mode == .live && plan.debounce == .milliseconds(100))
        #expect(plugin.nextOptions(after: plan, request: request(), step: 1) == nil)
        #expect(AskPluginRegistry.pluginIDs.contains(AskNotesPlugin.id))
        #expect(AskPluginRegistry.defaultKeywords.contains { $0.pluginID == AskNotesPlugin.id && $0.contains("笔记") })
    }

    @Test func `lists recent notes and searches`() async throws {
        let store = makeTestNotes()
        let first = makeTestNote("First", body: "alpha", pinned: true, at: 10)
        store.save(first)
        store.save(makeTestNote("Second", body: "beta", at: 20))
        let plugin = AskNotesPlugin(store: store)
        let all = try await plugin.run(request(), plan: plugin.plan(request()))
        #expect(all.items.map(\.title) == ["First", "Second", L("ask.notes.openWindow")])
        #expect(all.items[0].icon == .symbol("pin.fill") && all.items[1].icon == .symbol("note.text"))
        #expect(all.action(for: .enter)?.kind == .openNote(first.id))
        #expect(all.action(for: .commandC)?.kind == .copy("alpha"))
        #expect(all.action(for: .commandB)?.kind == .openNotes(id: nil))
        let found = try await plugin.run(request(" beta "), plan: plugin.plan(request("beta")))
        #expect(found.items.map(\.title) == ["Second", L("ask.notes.openWindow")] && found.original == "beta")
        var last = found
        last.selectedItem = 1
        #expect(last.action(for: .enter)?.kind == .openNotes(id: nil))
        let none = try await plugin.run(request("zzz"), plan: plugin.plan(request("zzz")))
        #expect(none.items.first?.title == L("ask.notes.noMatch") && none.items.first?.valid == false)
        let empty = try await AskNotesPlugin().run(request(), plan: plugin.plan(request()))
        #expect(empty.items.first?.title == L("ask.notes.empty"))
        let selection = try await plugin.run(request("beta", origin: .selection), plan: plugin.plan(request()))
        #expect(selection.items.count == 3, "a selection never filters the notes")
    }
}
