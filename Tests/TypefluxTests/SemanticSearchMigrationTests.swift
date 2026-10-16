import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("Resumable search generations", .serialized)
struct SemanticSearchMigrationTests {
    private func execute(_ url: URL, _ operation: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        let database = try #require(db)
        defer { sqlite3_close(database) }
        try operation(database)
    }

    private func legacy(_ url: URL, root: String, count: Int) throws {
        try execute(url) { db in
            try #require(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE profile(value TEXT NOT NULL);
            INSERT INTO profile VALUES('\(SemanticFilePolicy.profile)');
            CREATE TABLE files(path TEXT PRIMARY KEY,modified REAL NOT NULL,bytes INTEGER NOT NULL);
            CREATE TABLE chunks(id INTEGER PRIMARY KEY,path TEXT NOT NULL REFERENCES files(path) ON DELETE CASCADE,text TEXT NOT NULL,page INTEGER,vector BLOB NOT NULL);
            CREATE INDEX chunk_paths ON chunks(path);
            CREATE VIRTUAL TABLE lexical USING fts5(terms);
            BEGIN;
            INSERT INTO files VALUES('\(root)/book.txt',100,100);
            """, nil, nil, nil) == SQLITE_OK)
            var row: OpaquePointer?
            try #require(sqlite3_prepare_v2(
                db,
                "INSERT INTO chunks(id,path,text,vector) VALUES(?,?,'legacy zebra',?)",
                -1,
                &row,
                nil
            ) == SQLITE_OK)
            defer { sqlite3_finalize(row) }
            let vector = semanticVector(), transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for id in 1 ... count {
                sqlite3_reset(row); sqlite3_bind_int64(row, 1, Int64(id))
                sqlite3_bind_text(row, 2, root + "/book.txt", -1, transient)
                vector.withUnsafeBytes { _ = sqlite3_bind_blob(row, 3, $0.baseAddress, Int32($0.count), transient) }
                try #require(sqlite3_step(row) == SQLITE_DONE)
            }
            try #require(sqlite3_exec(
                db,
                "INSERT INTO lexical(rowid,terms) SELECT id,text FROM chunks; COMMIT",
                nil,
                nil,
                nil
            ) == SQLITE_OK)
        }
    }

    private func scalar(_ store: SemanticFileStore, _ sql: String) throws -> Int64 {
        try store.lock.withLock {
            let row = try store.statement(sql); defer { sqlite3_finalize(row) }
            try #require(sqlite3_step(row) == SQLITE_ROW)
            return sqlite3_column_int64(row, 0)
        }
    }

    @Test func `interrupted migration retains vectors and the usable previous lexical generation`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        try legacy(url, root: root.path, count: 513)
        func hits(_ database: SemanticFileStore) throws -> [AskFileHit] {
            try database.lexicalSearch(text: "legacy", query: .init("legacy"), type: .all,
                                       scope: semanticScope(root.path), limit: 5, cancelled: { false })
        }
        do {
            let store = try SemanticFileStore(url: url)
            #expect(try hits(store).count == 1)
            #expect(try scalar(store, "SELECT count(*) FROM vector_pages") == 0)
            #expect(throws: CancellationError.self) { try store.maintainSearchBatch(cancelled: { true }) }
            #expect(try scalar(store, "SELECT cursor FROM totals_migration") == 0)
            #expect(try store.maintainSearchBatch(cancelled: { false }))
            #expect(try scalar(store, "SELECT cursor FROM totals_migration") == 128)
        }
        let recovered = try SemanticFileStore(url: url)
        #expect(try scalar(recovered, "SELECT cursor FROM totals_migration") == 128)
        #expect(try hits(recovered).count == 1)
        while try recovered.maintainSearchBatch(cancelled: { false }) {}
        #expect(try recovered.counts().chunks == 513 && recovered.counts().files == 1)
        #expect(try scalar(recovered, "SELECT count(*) FROM lexical_v4") == 513)
        #expect(try scalar(recovered, "SELECT count(*) FROM vector_pages") == 3)
        #expect(try scalar(recovered, "SELECT count(*) FROM chunks WHERE length(vector)=3072") == 513)
        #expect(try !recovered.maintainSearchBatch(cancelled: { false }))
    }

    @Test func `normal reopen has bounded VM work regardless of chunk count`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        try legacy(url, root: root.path, count: 10000)
        let migrated = try SemanticFileStore(url: url)
        while try migrated.maintainSearchBatch(cancelled: { false }) {}
        for _ in 0 ..< 3 {
            var polls = 0
            let reopened = try SemanticFileStore(url: url, cancelled: { polls += 1; return polls > 40 })
            #expect(polls <= 40, "would interrupt a repeated full chunk enumeration")
            #expect(try reopened.counts().chunks == 10000)
            #expect(try !reopened.maintainSearchBatch(cancelled: { false }))
        }
    }

    @Test func `old writer changes are repaired on upgrade without a manual rebuild`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        try legacy(url, root: root.path, count: 1)
        do {
            let store = try SemanticFileStore(url: url)
            while try store.maintainSearchBatch(cancelled: { false }) {}
        }
        try execute(url) { db in
            try #require(sqlite3_exec(db, """
            BEGIN;
            UPDATE chunks SET text='résumé upgraded marker' WHERE id=1;
            DELETE FROM lexical WHERE rowid=1;
            INSERT INTO lexical(rowid,terms) VALUES(1,'résumé upgraded marker');
            INSERT INTO chunks(path,text,vector) SELECT path,'late zebra',vector FROM chunks WHERE id=1;
            INSERT INTO lexical(rowid,terms) VALUES(last_insert_rowid(),'late zebra');
            COMMIT;
            """, nil, nil, nil) == SQLITE_OK)
        }
        let upgraded = try SemanticFileStore(url: url)
        #expect(try scalar(upgraded, "SELECT count(*) FROM search_dirty") == 2)
        let before = try upgraded.lexicalSearch(text: "upgraded", query: .init("upgraded"), type: .all,
                                                scope: semanticScope(root.path), limit: 5, cancelled: { false })
        #expect(before.count == 1, "legacy fallback stays usable before repair")
        while try upgraded.maintainSearchBatch(cancelled: { false }) {}
        #expect(try scalar(upgraded, "SELECT count(*) FROM search_dirty") == 0)
        #expect(try upgraded.counts().chunks == 2 && upgraded.counts().files == 1)
        #expect(try upgraded.lexicalSearch(text: "resume", query: .init("resume"), type: .all,
                                           scope: semanticScope(root.path), limit: 5, cancelled: { false }).count == 1)
        try upgraded.remove(root.path + "/book.txt")
        #expect(try upgraded.counts() == .init())
        #expect(try scalar(upgraded, "SELECT count(*) FROM lexical_v4") == 0)
    }

    @Test func `model-space change cleans a long file in resumable row batches`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("legacy.sqlite")
        try legacy(url, root: root.path, count: 513)
        let old = try SemanticFileStore(url: url)
        while try old.maintainSearchBatch(cancelled: { false }) {}
        let scope = semanticScope(root.path)
        try old.saveEventID(100, scope: scope, volumeSignature: "migration-fixture-volume")
        let reset = try SemanticFileStore(url: url, profile: "replacement-space")
        #expect(try reset.completedEventID(scope: scope, volumeSignature: "migration-fixture-volume") == nil)
        #expect(try reset.search(vector: semanticVector(), text: "legacy", query: .init("legacy"), type: .all,
                                 scope: semanticScope(root.path), limit: 5, cancelled: { false }).isEmpty)
        #expect(try reset.maintainSearchBatch(cancelled: { false }))
        #expect(try scalar(reset, "SELECT count(*) FROM chunks") == 385)
        let resumed = try SemanticFileStore(url: url, profile: "replacement-space")
        #expect(try scalar(resumed, "SELECT count(*) FROM chunks") == 385)
        while try resumed.maintainSearchBatch(cancelled: { false }) {}
        #expect(try resumed.counts() == .init())
        #expect(try scalar(resumed, "SELECT count(*) FROM profile_reset") == 0)
    }
}
