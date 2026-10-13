import AppKit
import SQLite3
import SwiftUI
@testable import Typeflux
import XCTest

final class ClipboardSnippetTests: XCTestCase {
    private var directory: URL!
    private var store: SQLiteClipboardHistoryStore!

    override func setUp() {
        super.setUp()
        directory = ClipboardTestSupport.temporaryDirectory("ClipboardSnippetTests")
        store = SQLiteClipboardHistoryStore(baseDir: directory)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func save(_ text: String = "  exact\n    text.\n", name: String = "Signature", alias: String = "signature",
                      id: UUID? = nil) throws -> ClipboardItem {
        try store.saveSnippet(id: id, name: name, text: text, alias: alias,
                              source: ClipboardSource(bundleID: "test.app", appName: "Test"), at: .distantPast)
    }

    func testConversionPersistenceAndRecaptureAreIndependent() throws {
        let original = try XCTUnwrap(store.record(.text("original"), source: nil, at: Date()))
        store.setPinned(true, id: original.id)
        let saved = try save(id: original.id)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertFalse(saved.isPinned)
        XCTAssertEqual(saved.text, "  exact\n    text.\n")
        store = nil
        store = SQLiteClipboardHistoryStore(baseDir: directory)
        XCTAssertEqual(store.items(limit: 10), [saved])
        store.setPinned(true, id: saved.id)
        XCTAssertFalse(try XCTUnwrap(store.items(limit: 10).first).isPinned)
        let recopy = try XCTUnwrap(try store.record(.text(XCTUnwrap(saved.text)), source: nil, at: Date()))
        XCTAssertNotEqual(recopy.id, saved.id)
        XCTAssertNil(recopy.snippet)
        let edited = try save("different", name: "Renamed", alias: "another", id: saved.id)
        XCTAssertEqual(edited.snippet, ClipboardSnippet(name: "Renamed", alias: "another"))
        XCTAssertEqual(store.items(limit: 10).count, 2)
        XCTAssertEqual(try store.record(.text(XCTUnwrap(saved.text)), source: nil, at: Date())?.id, recopy.id)
        store.delete(id: saved.id)
        XCTAssertEqual(store.items(limit: 10).map(\.id), [recopy.id])
    }

    func testEveryCleanupPathPreservesUnpinnedSnippets() throws {
        let snippet = try save()
        for cleanup in [
            { self.store.purge(olderThan: .distantFuture) },
            { self.store.trim(toMaxCount: 0) },
            { self.store.deleteUnpinned(sourceBundleID: "test.app") },
            { self.store.deleteUnpinned(sourceBundleID: nil) }
        ] {
            store.record(
                .text(UUID().uuidString),
                source: ClipboardSource(bundleID: "test.app", appName: "Test"),
                at: .distantPast
            )
            cleanup()
            XCTAssertEqual(store.items(limit: 10), [snippet])
        }
        store.trim(toMaxImageBytes: 0)
        XCTAssertEqual(store.items(limit: 10), [snippet])
    }

    func testValidationAliasUniquenessAndRollback() throws {
        let first = try save(alias: "  Ｍｙ   Signature  ")
        XCTAssertThrowsError(try save(alias: "my signature")) {
            XCTAssertEqual($0 as? ClipboardSnippetError, .duplicateAlias)
        }
        XCTAssertEqual(store.items(limit: 10), [first])
        _ = try save(alias: "MY SIGNATURE", id: first.id)
        _ = try save(alias: "")
        _ = try save(alias: "")
        for (name, text, alias, expected) in [
            (" ", "ok", "", ClipboardSnippetError.invalidName),
            (String(repeating: "x", count: 61), "ok", "", .invalidName),
            ("ok", " \n", "", .emptyText),
            ("ok", "ok", String(repeating: "x", count: 41), .invalidAlias)
        ] {
            XCTAssertThrowsError(try save(text, name: name, alias: alias)) {
                XCTAssertEqual($0 as? ClipboardSnippetError, expected)
            }
        }
        XCTAssertThrowsError(try save(alias: "", id: UUID())) {
            XCTAssertEqual($0 as? ClipboardSnippetError, .missingItem)
        }
        let image = try XCTUnwrap(store.record(
            .image(png: Data([1]), pixelWidth: 1, pixelHeight: 1),
            source: nil,
            at: Date()
        ))
        XCTAssertThrowsError(try save(alias: "", id: image.id))
        XCTAssertEqual(store.items(limit: 10).count, 4)
    }

    private func sql(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testMigratesLegacyDatabaseAndReopensIdempotently() throws {
        store = nil
        try FileManager.default.removeItem(at: directory.appendingPathComponent("clipboard.sqlite"))
        let id = UUID()
        try sql("""
        CREATE TABLE clipboard_items (id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, date REAL NOT NULL,
        text TEXT, file_paths TEXT, image_path TEXT, image_width INTEGER, image_height INTEGER,
        byte_size INTEGER NOT NULL DEFAULT 0, content_hash TEXT NOT NULL UNIQUE, source_bundle_id TEXT,
        source_app_name TEXT, pinned INTEGER NOT NULL DEFAULT 0);
        INSERT INTO clipboard_items (id,payload,date,text,content_hash,pinned) VALUES
        ('\(id.uuidString)','text',0,'legacy','legacy-hash',1);
        """)
        store = SQLiteClipboardHistoryStore(baseDir: directory)
        let item = try XCTUnwrap(store.items(limit: 10).first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.text, "legacy")
        XCTAssertTrue(item.isPinned)
        XCTAssertNil(item.snippet)
        let saved = try save(id: id)
        store = nil
        store = SQLiteClipboardHistoryStore(baseDir: directory)
        XCTAssertEqual(store.items(limit: 10), [saved])
    }

    func testWriteFailureRollsBackAndLeavesOriginalIntact() throws {
        let original = try XCTUnwrap(store.record(.text("original"), source: nil, at: Date(timeIntervalSince1970: 1000)))
        try sql(
            "CREATE TRIGGER reject_snippet BEFORE UPDATE ON clipboard_items BEGIN SELECT RAISE(ABORT, 'test'); END;"
        )
        XCTAssertThrowsError(try save(id: original.id))
        XCTAssertEqual(store.items(limit: 10), [original])
        try sql("DROP TRIGGER reject_snippet;")
        XCTAssertNoThrow(try save(id: original.id))
    }

    func testFeedSeparatesSnippetsAndSearchesMetadataWithoutFoldingVoice() throws {
        let item = try save("voice words", name: "Office", alias: "my address")
        let entries = ClipboardFeed.entries(
            clipboardItems: [item],
            voiceRecords: [HistoryRecord(date: Date(), transcriptText: "voice words")],
            pinnedVoiceRecordIDs: []
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(ClipboardFeed.filter(entries, category: .all, query: "").map(\.kind), [.voice])
        for query in ["Office", "address", "voice", "Test"] {
            XCTAssertEqual(ClipboardFeed.filter(entries, category: .snippet, query: query).map(\.title), ["Office"])
        }
        let snippet = ClipboardFeed.entry(for: item)
        XCTAssertEqual(ClipboardFeed.section(for: snippet, now: Date()), .snippets)
        XCTAssertFalse(ClipboardEntryAction.available(for: snippet).contains(.togglePin))
        XCTAssertFalse(ClipboardEntryAction.available(for: snippet).contains(.deleteAllFromApp))
        XCTAssertTrue(ClipboardEntryAction.available(for: snippet).contains(.editSnippet))
        XCTAssertTrue(ClipboardEntryFormatter.details(for: snippet).contains(L(
            "clipboard.snippet.voiceAlias",
            "my address"
        )))
        XCTAssertEqual(ClipboardCategory.allCases, [.all, .text, .image, .link, .snippet])
    }

    func testExplicitVoiceCommandNormalization() {
        for command in ["插入片段 邮件签名。", "插入片段邮件签名", " 插入片段 邮件签名！ "] {
            XCTAssertEqual(ClipboardSnippetCommand.alias(in: command), "邮件签名")
        }
        XCTAssertEqual(ClipboardSnippetCommand.alias(in: "Insert Snippet ＭＹ   signature."), "my signature")
        for text in ["讨论一下插入片段", "我的邮件签名", "插入片段", "insert snippets signature", ""] {
            XCTAssertNil(ClipboardSnippetCommand.alias(in: text))
        }
    }

    func testModelKeepsFailedDraftThenSavesAndConfirmsDeletion() throws {
        let model = ClipboardPanelModel()
        let item = try XCTUnwrap(store.record(.text("original"), source: nil, at: Date()))
        model.reset(entries: [ClipboardFeed.entry(for: item)])
        model.perform(.saveSnippet)
        model.snippetDraft?.name = ""
        model.commitSnippet()
        XCTAssertNotNil(model.snippetError)
        model.snippetDraft?.name = "Saved"
        model.commitSnippet()
        XCTAssertEqual(model.snippetError, L("clipboard.snippet.error.unavailable"))
        model.onSaveSnippet = { _ in throw NSError(domain: "test", code: 1) }
        model.commitSnippet()
        XCTAssertEqual(model.snippetDraft?.text, "original")
        model.onSaveSnippet = { draft in try self.save(draft.text, name: draft.name, alias: draft.alias, id: item.id) }
        model.commitSnippet()
        XCTAssertNil(model.snippetDraft)
        XCTAssertEqual(model.category, .snippet)
        XCTAssertEqual(model.selectedEntry?.title, "Saved")
        model.perform(.togglePin)
        XCTAssertFalse(try XCTUnwrap(model.selectedEntry?.isPinned))
        model.requestClearUnpinned()
        XCTAssertNil(model.pendingConfirmation)
        model.perform(.editSnippet)
        model.cancelSnippetEdit()
        XCTAssertNil(model.snippetDraft)
        model.perform(.delete)
        XCTAssertNotNil(model.pendingConfirmation)
        var command: ClipboardPanelCommand?
        model.onCommand = { command = $0 }
        model.confirmPending()
        XCTAssertEqual(command, try .deleteSnippet(XCTUnwrap(model.selectedEntry)))
        model.commitSnippet()
    }

    @MainActor
    func testNativeSnippetStatesRender() throws {
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }
        let model = ClipboardPanelModel()
        let item = try save()
        model.reset(entries: [ClipboardFeed.entry(for: item)])
        model.category = .snippet
        for state in ["list", "editor", "error"] {
            if state != "list" {
                model.perform(.editSnippet)
            }
            if state == "error" {
                model.snippetError = L("clipboard.snippet.error.duplicateAlias")
            }
            let host = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: 0)
                .environment(\.askGlassMaterialOverride, .opaque)
                .environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 512, height: 560)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            if let path = ProcessInfo.processInfo.environment["TYPEFLUX_SNIPPET_SNAPSHOT_DIR"] {
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("snippet-\(state).png"))
            }
        }
    }
}
