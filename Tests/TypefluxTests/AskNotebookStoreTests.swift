import AppKit
import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Notebook store, import and export", .exclusiveUIState)
@MainActor
struct AskNotebookStoreTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFirstReleaseDatabaseIsMigrated() throws {
        let url = try directory().appendingPathComponent("notes.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let old = """
        CREATE TABLE notes (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, command TEXT NOT NULL,
            keyword TEXT NOT NULL, input TEXT NOT NULL, model TEXT, source_app TEXT, source_bundle_id TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]', pinned INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
            updated_at REAL NOT NULL, edited_at REAL);
        INSERT INTO notes VALUES ('\(UUID().uuidString)', 'Shot', 'text', 'Screenshot to Text', 'ocr', '', NULL, NULL, NULL,
            '[]', 0, 10, 10, NULL);
        INSERT INTO notes VALUES ('\(UUID().uuidString)', 'Explain', 'x', 'Explain', 'ex', 'in', NULL, NULL, NULL,
            '["a"]', 1, 20, 20, NULL);
        """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let store = SQLiteAskNoteStore(url: url)
        store.notificationCenter = NotificationCenter()
        let notes = store.list(AskNoteQuery())
        #expect(notes.map(\.title) == ["Explain", "Shot"])
        #expect(notes.map(\.source) == [.command, .screenshot] && notes.allSatisfy { $0.author == .user && !$0.isDeleted })
        #expect(store.sources().first { $0.name == "screenshot" }?.count == 1)
        #expect(store.commands().map(\.name) == ["Explain"], "screenshot text is not an AI command")
        // Opening again leaves it as it is.
        let again = SQLiteAskNoteStore(url: url)
        #expect(again.count(.all) == 2)
        #expect(SQLiteAskNoteStore.screenshotCommandNames.contains("截图取字"))
    }

    @Test func failedMigrationRollsBackItsColumnsAndCanBeRetried() throws {
        let url = try directory().appendingPathComponent("notes.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TABLE notes (id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, command TEXT NOT NULL,
            keyword TEXT NOT NULL, input TEXT NOT NULL, model TEXT, source_app TEXT, source_bundle_id TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]', pinned INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
            updated_at REAL NOT NULL, edited_at REAL);
        INSERT INTO notes VALUES ('\(UUID().uuidString)', 'Shot', 'text', 'Screenshot to Text', 'ocr', '', NULL, NULL, NULL,
            '[]', 0, 10, 10, NULL);
        CREATE TRIGGER reject_migration BEFORE UPDATE ON notes BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END;
        """, nil, nil, nil) == SQLITE_OK)
        let failed = SQLiteAskNoteStore(url: url)
        #expect(!failed.save(makeTestNote()))
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM pragma_table_info('notes') WHERE name = 'source_kind'",
                                   -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 0)
        sqlite3_finalize(statement)
        #expect(sqlite3_exec(db, "DROP TRIGGER reject_migration", nil, nil, nil) == SQLITE_OK)
        let reopened = SQLiteAskNoteStore(url: url)
        #expect(reopened.count(.all) == 1 && reopened.list(AskNoteQuery()).first?.source == .screenshot)
    }

    @Test func trashScopesSortingAndRevisions() throws {
        let store = makeTestNotes()
        let now = Date()
        var a = makeTestNote("b title", body: "alpha", tags: ["t"], at: now.timeIntervalSince1970 - 60)
        a.source = .chat
        a.conversationID = "c1"
        a.messageID = "m1"
        let old = makeTestNote("A title", body: "beta", at: now.timeIntervalSince1970 - 30 * 86400)
        store.save(a)
        store.save(old)
        #expect(store.count(.recent) == 1 && store.list(AskNoteQuery(scope: .recent)).first?.id == a.id)
        #expect(store.list(AskNoteQuery(scope: .source(.chat))).map(\.id) == [a.id])
        #expect(store.list(AskNoteQuery(sort: .title)).map(\.title) == ["A title", "b title"])
        let saved = try #require(store.note(id: a.id))
        #expect(saved.conversationID == "c1" && saved.messageID == "m1" && saved.source == .chat)

        store.trash(ids: [a.id], at: now)
        store.trash(ids: [], at: now)
        #expect(store.count(.all) == 1 && store.count(.trash) == 1 && store.tags().isEmpty)
        #expect(store.list(AskNoteQuery(scope: .trash)).first?.deletedAt != nil)
        #expect(store.note(id: a.id)?.isDeleted == true)
        store.purgeTrash(before: now.addingTimeInterval(-1))
        #expect(store.count(.trash) == 1, "kept until 30 days have passed")
        store.purgeTrash(before: now.addingTimeInterval(1))
        #expect(store.count(.trash) == 0 && store.note(id: a.id) == nil)

        for index in 0 ..< 25 {
            var version = old
            version.body = "v\(index)"
            store.saveRevision(version, at: Date(timeIntervalSince1970: TimeInterval(1000 + index)))
        }
        let revisions = store.revisions(of: old.id)
        #expect(revisions.count == SQLiteAskNoteStore.revisionLimit && revisions.first?.body == "v24")
        store.deleteRevision(of: old.id, at: Date(timeIntervalSince1970: 1024))
        #expect(store.revisions(of: old.id).first?.body == "v23")
        #expect(store.revisions(of: UUID()).isEmpty)
    }

    @Test func conditionalSaveAndItsRevisionCommitTogether() throws {
        let url = try directory().appendingPathComponent("notes.sqlite")
        let store = SQLiteAskNoteStore(url: url)
        store.notificationCenter = NotificationCenter()
        let original = makeTestNote("Original", body: "before")
        #expect(store.save(original))
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TRIGGER reject_update BEFORE UPDATE ON notes WHEN NEW.body = 'blocked'
        BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
        """, nil, nil, nil) == SQLITE_OK)

        var changed = original
        changed.body = "blocked"
        #expect(!store.save(changed, replacing: original, revisionAt: .now))
        #expect(store.note(id: original.id) == original)
        #expect(store.revisions(of: original.id).isEmpty, "a failed body write rolls back its revision")

        changed.body = "after"
        #expect(store.save(changed, replacing: original, revisionAt: .now))
        #expect(store.note(id: original.id) == changed)
        #expect(store.revisions(of: original.id).map(\.body) == ["before"])
        var stale = original
        stale.body = "stale overwrite"
        #expect(!store.save(stale, replacing: original, revisionAt: .now))
        #expect(store.note(id: original.id) == changed && store.revisions(of: original.id).count == 1)
        stale = changed
        stale.tags = ["new"]
        #expect(store.save(stale, replacing: changed, revisionAt: nil))
        #expect(store.revisions(of: original.id).count == 1, "metadata saves need no text revision")
        var differentID = stale
        differentID.id = UUID()
        #expect(!store.save(differentID, replacing: stale, revisionAt: nil))
        #expect(store.note(id: differentID.id) == nil)
    }

    @Test func conditionalSaveUsesThePersistedDatePrecision() {
        let store = makeTestNotes()
        let precise = Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_1)
        var original = makeTestNote("Precise")
        original.createdAt = precise
        original.updatedAt = precise
        original.editedAt = precise
        original.deletedAt = precise
        #expect(store.save(original))
        var changed = original
        changed.body = "Updated"
        #expect(store.save(changed, replacing: original, revisionAt: nil))
        #expect(store.note(id: original.id)?.body == "Updated")
    }

    @Test func batchRestoreRollsBackAndPermanentDeleteRemovesRevisions() throws {
        let url = try directory().appendingPathComponent("notes.sqlite")
        let store = SQLiteAskNoteStore(url: url)
        store.notificationCenter = NotificationCenter()
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
        CREATE TRIGGER reject_insert BEFORE INSERT ON notes WHEN NEW.title = 'blocked'
        BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
        """, nil, nil, nil) == SQLITE_OK)
        let first = makeTestNote("first")
        let blocked = makeTestNote("blocked")
        store.restore([first, blocked])
        #expect(store.count(.all) == 0, "a batch never leaves only its first notes restored")
        #expect(store.save(first))
        store.saveRevision(first, at: .now)
        store.delete(ids: [first.id])
        #expect(store.note(id: first.id) == nil && store.revisions(of: first.id).isEmpty)
    }

    @Test func textWithNullCharactersAndConversationFiltersRoundTrip() throws {
        let store = makeTestNotes()
        var first = makeTestNote("Title\u{0}尾", body: "before\u{0}after")
        first.conversationID = "chat-1"
        first.originalBody = "original\u{0}text"
        var second = makeTestNote("Other")
        second.conversationID = "chat-2"
        #expect(store.save(first) && store.save(second))
        #expect(store.note(id: first.id) == first)
        #expect(store.list(AskNoteQuery(conversationID: "chat-1")) == [first])
        #expect(store.list(AskNoteQuery(conversationID: "missing")).isEmpty)
        store.saveRevision(first, at: .now)
        #expect(store.revisions(of: first.id).first?.body == first.body)
        store.trash(ids: [first.id], at: .now)
        #expect(store.list(AskNoteQuery(conversationID: "chat-1")).isEmpty)
        #expect(store.list(AskNoteQuery(scope: .trash, conversationID: "chat-1")).first?.id == first.id)
    }

    @Test func markdownRoundTripKeepsIndentationHardBreaksAndQuotedTags() {
        let note = makeTestNote("Code", body: "    let value = 1\n\nText  ", tags: ["one,two", "say \"hi\"", "back\\slash"])
        let exported = AskNoteExporter.markdown(note)
        let imported = AskNoteImporter.note(exported, fileName: "ignored")
        #expect(imported.body == note.body)
        #expect(imported.tags == note.tags)
        #expect(AskNoteExporter.markdown(note, options: .init(frontMatter: false)) == note.body + "\n")
        #expect(AskNoteExporter.merged([note]).contains("\n\n    let value = 1"))
    }

    @Test func revisionsWithEqualTimesKeepTheNewestAndDeleteOneAtATime() {
        let store = makeTestNotes()
        var note = makeTestNote()
        #expect(store.save(note))
        let date = Date(timeIntervalSince1970: 1000)
        for index in 0 ..< 25 {
            note.body = "version \(index)"
            store.saveRevision(note, at: date)
        }
        #expect(store.revisions(of: note.id).map(\.body) == (5 ..< 25).reversed().map { "version \($0)" })
        store.deleteRevision(of: note.id, at: date)
        #expect(store.revisions(of: note.id).count == 19 && store.revisions(of: note.id).first?.body == "version 23")
    }

    @Test func exportFileNamesFitUnicodeFileSystemLimits() throws {
        let note = makeTestNote(String(repeating: "😀", count: 80), body: "text")
        #expect(AskNoteExporter.fileName(note).utf8.count <= 255)
        let folder = try AskNoteExporter.exportFolder([note], into: directory())
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let file = try #require(files.first)
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("text"))
        #expect(AskNoteExporter.fileName(makeTestNote("a\u{0}b")) == "a b.md")
    }

    @Test func exportsMarkdownHTMLPDFAndFolders() throws {
        var note = makeTestNote("A/B: <C>", body: "## Hi\n\n**bold**", input: "line 1\nline 2", tags: ["x"])
        note.source = .chat
        let plain = AskNoteExporter.markdown(note, options: .init(frontMatter: false, original: true))
        #expect(plain == "> line 1\n> line 2\n\n## Hi\n\n**bold**\n")
        let full = AskNoteExporter.markdown(note)
        #expect(full.hasPrefix("---\ntitle: \"A/B: <C>\"") && full.contains("from: chat") && full.contains("tags: [\"x\"]"))
        let html = AskNoteExporter.html(note)
        #expect(html.contains("<title>A/B: &lt;C&gt;</title>") && html.contains("<strong>bold</strong>"))
        #expect(html.contains("class=\"meta\"") && !AskNoteExporter.html(note, options: .init(frontMatter: false)).contains("class=\"meta\""))
        let pdf = try #require(AskNoteExporter.pdf(note))
        #expect(String(decoding: pdf.prefix(4), as: UTF8.self) == "%PDF")
        #expect(AskNoteExporter.data(note, format: .html)?.isEmpty == false)
        #expect(AskNoteExporter.fileName(note, format: .pdf) == "A B   C.pdf")
        #expect(AskNoteExporter.merged([note, makeTestNote("Two", body: "2")]) == "# A/B: <C>\n\n## Hi\n\n**bold**\n\n---\n\n# Two\n\n2")

        let root = try directory()
        let folder = try AskNoteExporter.exportFolder([note, note, makeTestNote("Other")], into: root,
                                                      date: Date(timeIntervalSince1970: 0))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["A B   C 2.md", "A B   C.md", "Other.md"])
        let second = try AskNoteExporter.exportFolder([note], into: root, date: Date(timeIntervalSince1970: 0))
        #expect(second.lastPathComponent == folder.lastPathComponent + " 2")
        var used: Set<String> = []
        #expect(AskNoteExporter.uniqueName("x", used: &used) == "x" && AskNoteExporter.uniqueName("X", used: &used) == "X 2")
    }

    @Test func importsMarkdownFiles() throws {
        let root = try directory()
        let withFront = root.appendingPathComponent("a.md")
        try "---\ntitle: Front\ntags: [one, \"#two\", one]\ncreated: 2026-01-01T00:00:00Z\nupdated: 2025-01-01T00:00:00Z\ncommand: Sum\n---\nBody"
            .write(to: withFront, atomically: true, encoding: .utf8)
        let heading = root.appendingPathComponent("b.markdown")
        try "intro\n## Heading Title\ntext".write(to: heading, atomically: true, encoding: .utf8)
        let plain = root.appendingPathComponent("plain name.txt")
        try "just text".write(to: plain, atomically: true, encoding: .utf8)
        let image = root.appendingPathComponent("c.png")
        try Data([0x89]).write(to: image)
        let binary = root.appendingPathComponent("d.md")
        try Data([0xFF, 0xFE, 0x00]).write(to: binary)
        let big = root.appendingPathComponent("e.md")
        try String(repeating: "x", count: AskNoteImporter.maximumBytes + 1).write(to: big, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 500)
        let result = AskNoteImporter.notes(from: [withFront, heading, plain, image, binary, big], now: now)
        #expect(result.notes.map(\.title) == ["Front", "Heading Title", "plain name"])
        #expect(result.skipped == ["c.png", "d.md", "e.md"])
        let first = try #require(result.notes.first)
        #expect(first.tags == ["one", "two"] && first.body == "Body" && first.command == "Sum" && first.source == .import)
        #expect(first.updatedAt == first.createdAt, "an update before creation is not kept")
        #expect(result.notes[2].createdAt == now)
        #expect(AskNoteImporter.note("", fileName: "").title == L("ask.notes.untitled"))
        let many = Array(repeating: plain, count: AskNoteImporter.maximumFiles + 2)
        #expect(AskNoteImporter.notes(from: many).skipped.count == 2)
    }
}
