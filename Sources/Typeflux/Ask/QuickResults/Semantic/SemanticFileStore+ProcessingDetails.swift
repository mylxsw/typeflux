import Darwin
import Foundation
import SQLite3

extension SemanticFileStore {
    enum ProcessingSection: Equatable, Sendable { case completed, pending }

    struct ProcessingItem: Identifiable, Sendable {
        let path: String
        let state: String
        let priority: SemanticMediaPriority
        var bytes: Int64?
        var modified: Date?
        let processingSeconds: TimeInterval?
        let completedAt: Date?
        let page: Int?

        var id: String { path }
    }

    struct ProcessingPage: Sendable {
        var items: [ProcessingItem]
        let total: Int
    }

    /// A bounded read for the details sheet. File metadata fallback runs after releasing the DB lock.
    func processingPage(_ section: ProcessingSection, offset: Int, limit: Int = 50) throws -> ProcessingPage {
        let limit = min(100, max(1, limit)), offset = max(0, offset)
        var page = try lock.withLock { () throws -> ProcessingPage in
            let pending = section == .pending
            let countSQL = pending
                ? "SELECT count(*) FROM work_queue"
                : "SELECT count(*) FROM jobs j WHERE j.state IN ('done','skipped','failed') AND NOT EXISTS(SELECT 1 FROM work_queue w WHERE w.path=j.path)"
            let total = try countQuery(countSQL)
            let sql = pending ? """
                SELECT w.path,w.priority,f.bytes,f.modified,j.processing_seconds,j.completed_at,j.cursor,
                    COALESCE(j.state,'pending')
                FROM work_queue w LEFT JOIN files f ON f.path=w.path LEFT JOIN jobs j ON j.path=w.path
                ORDER BY w.priority,w.turn LIMIT ? OFFSET ?
                """ : """
                SELECT j.path,-1,f.bytes,f.modified,j.processing_seconds,j.completed_at,j.cursor,j.state
                FROM jobs j LEFT JOIN files f ON f.path=j.path
                WHERE j.state IN ('done','skipped','failed')
                    AND NOT EXISTS(SELECT 1 FROM work_queue w WHERE w.path=j.path)
                ORDER BY j.completed_at DESC,j.path LIMIT ? OFFSET ?
                """
            let row = try statement(sql)
            defer { sqlite3_finalize(row) }
            bind(row, [limit, offset])
            var items: [ProcessingItem] = []
            var step = sqlite3_step(row)
            while step == SQLITE_ROW {
                let path = string(row, 0)
                let priority = pending ? SemanticMediaPriority(rawValue: Int(sqlite3_column_int(row, 1)))
                    ?? SemanticMediaPriority.of(path) : SemanticMediaPriority.of(path)
                let cursor = string(row, 6).data(using: .utf8)
                    .flatMap { try? JSONDecoder().decode(SemanticContentCursor.self, from: $0) }
                items.append(.init(path: path, state: string(row, 7), priority: priority,
                                   bytes: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(row, 2),
                                   modified: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                                       : Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                                   processingSeconds: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil
                                       : sqlite3_column_double(row, 4),
                                   completedAt: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil
                                       : Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                                   page: priority == .document && (cursor?.page ?? 0) > 0 ? cursor?.page : nil))
                step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            return .init(items: items, total: total)
        }
        // Only the visible page is probed, without following a symlink or reading file contents.
        for index in page.items.indices where page.items[index].bytes == nil || page.items[index].modified == nil {
            var info = stat()
            guard lstat(page.items[index].path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if page.items[index].bytes == nil { page.items[index].bytes = Int64(info.st_size) }
            if page.items[index].modified == nil {
                page.items[index].modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            }
        }
        return page
    }

    private func countQuery(_ sql: String) throws -> Int {
        let row = try statement(sql)
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(row, 0))
    }
}
