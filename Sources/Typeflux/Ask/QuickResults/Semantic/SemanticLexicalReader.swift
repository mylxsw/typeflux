import Foundation
import SQLite3

/// A WAL reader with its own lock. Vector scans and index transactions never hold this lock.
final class SemanticLexicalReader: @unchecked Sendable {
    private let lock = NSLock()
    private var database: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            sqlite3_close(database); database = nil; throw SemanticFileStore.Failure.database
        }
        sqlite3_busy_timeout(database, 50)
    }

    deinit { sqlite3_close(database) }
    func close() {
        lock.withLock { sqlite3_close(database); database = nil }
    }

    // Apply scope and type restrictions before counting winning files.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    func search(text: String, query: AskSearchQuery, type: AskFileType, scope: AskFileScope,
                limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        let terms = SemanticFilePolicy.searchTerms(text).prefix(64)
        guard limit > 0, !terms.isEmpty else { return [] }
        let waiting = ProcessInfo.processInfo.systemUptime
        return try lock.withLock {
            SemanticSearchTrace.current?.measure("fts-lock-wait",
                milliseconds: (ProcessInfo.processInfo.systemUptime - waiting) * 1000)
            guard !cancelled() else { throw CancellationError() }
            guard let database else { throw SemanticFileStore.Failure.database }
            var statement: OpaquePointer?
            let sql = """
            SELECT c.path,c.text,c.page,f.modified
            FROM lexical JOIN chunks c ON c.id=lexical.rowid JOIN files f ON f.path=c.path
            WHERE lexical MATCH ? ORDER BY rank
            """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SemanticFileStore.Failure.database
            }
            defer { sqlite3_finalize(statement) }
            let match = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, match, -1, transient)
            func string(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            var hits: [AskFileHit] = [], seen = Set<String>()
            while true {
                guard !cancelled() else { throw CancellationError() }
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE {
                    return hits
                }
                guard step == SQLITE_ROW else { throw SemanticFileStore.Failure.database }
                let path = string(0), ext = (path as NSString).pathExtension.lowercased()
                guard !seen.contains(path), scope.includes(path, isDirectory: false),
                      SemanticFilePolicy.allows(path), type.matches(kind: .file, extension: ext),
                      query.fileExtension == nil || query.fileExtension == ext else { continue }
                if let folder = query.folder,
                   !AskFileIndexState.contains(
                       AskSearchText.normalize((path as NSString).deletingLastPathComponent),
                       folder
                   ) {
                    continue
                }
                seen.insert(path)
                let page = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(
                    statement,
                    2
                ))
                hits.append(.init(path: path, name: (path as NSString).lastPathComponent, kind: .file,
                                  modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                                  score: 0.18, evidence: .init(text: String(string(1).prefix(180)), page: page)))
                if hits.count == min(100, limit) {
                    return hits
                }
            }
        }
    }
}
