import Foundation
import SQLite3
import Testing
@testable import Typeflux

@Suite("SQLite read cancellation", .serialized)
struct SemanticSQLiteCancellationTests {
    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(":memory:", &database) == SQLITE_OK)
        let connection = try #require(database)
        defer { sqlite3_close(connection) }
        try body(connection)
    }

    private func scan(_ count: Int) -> String {
        "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<\(count)) SELECT sum(x) FROM n"
    }

    @Test func interruptsSQLiteBeforeItsFirstResultAndRemovesTheCallback() throws {
        try fixture { database in
            var polls = 0
            #expect(throws: CancellationError.self) {
                try SemanticSQLiteCancellation.read(database, cancelled: { polls += 1; return polls >= 8 }, operation: {
                    let status = sqlite3_exec(database, scan(1_000_000), nil, nil, nil)
                    #expect(status == SQLITE_INTERRUPT, "cancellation must interrupt the VM before its first result")
                    guard status == SQLITE_OK else { throw SemanticFileStore.Failure.database }
                })
            }
            #expect(polls >= 8)
            // A substantial second statement detects a callback accidentally left installed.
            #expect(sqlite3_exec(database, scan(10_000), nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func cancelledEntryNeverStartsTheRead() throws {
        try fixture { database in
            var started = false
            #expect(throws: CancellationError.self) {
                try SemanticSQLiteCancellation.read(database, cancelled: { true }, operation: { started = true })
            }
            #expect(!started)
        }
    }

    @Test func successfulReadsAndDatabaseFailuresPreserveTheirResults() throws {
        try fixture { database in
            var cancelled = false
            let value = try SemanticSQLiteCancellation.read(database, cancelled: { cancelled }, operation: {
                #expect(sqlite3_exec(database, scan(10_000), nil, nil, nil) == SQLITE_OK)
                return 42
            })
            #expect(value == 42)
            cancelled = true
            #expect(sqlite3_exec(database, scan(10_000), nil, nil, nil) == SQLITE_OK)
            #expect(throws: SemanticFileStore.Failure.self) {
                try SemanticSQLiteCancellation.read(database, cancelled: { false }, operation: {
                    guard sqlite3_exec(database, "SELECT * FROM missing", nil, nil, nil) == SQLITE_OK else {
                        throw SemanticFileStore.Failure.database
                    }
                })
            }
        }
    }
}
