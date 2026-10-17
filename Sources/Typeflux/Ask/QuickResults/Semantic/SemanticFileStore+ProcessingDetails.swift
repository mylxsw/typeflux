import Darwin
import Foundation
import SQLite3

extension SemanticFileStore {
    enum ProcessingSection: Equatable, Sendable { case completed, pending }

    struct ProcessingItem: Identifiable, Sendable {
        let path: String
        var state: String
        let priority: SemanticMediaPriority
        var bytes: Int64?
        var modified: Date?
        let processingSeconds: TimeInterval?
        let completedAt: Date?
        let page: Int?
        var generation: String?
        var reason: String?
        var queued = false
        var offset: Int64 = 0
        var savedChunks = 0
        var encodedChunks = 0
        var savedMediaSegments = 0
        var audioCovered: Double?
        var videoChecked: Double?

        var canRetry: Bool {
            generation != nil && (state == "partial" || state == "failed")
                && reason != "password-required" && reason != "unsupported-document"
        }

        var displayState: String {
            if queued && state != "partial" { return "pending" }
            return reason == "audio-silent" ? "skipped" : state
        }

        var id: String {
            path
        }
    }

    struct ProcessingPage: Sendable {
        var items: [ProcessingItem]
        let total: Int
    }

    // A bounded read for the details sheet. File metadata fallback runs after releasing the DB lock.
    // swiftlint:disable:next function_body_length
    func processingPage(_ section: ProcessingSection, offset: Int, limit: Int = 50) throws -> ProcessingPage {
        let limit = min(100, max(1, limit)), offset = max(0, offset)
        var page = try lock.withLock { () throws -> ProcessingPage in
            let pending = section == .pending
            let countSQL = pending
                ? "SELECT count(*) FROM work_queue"
                : """
                SELECT count(*) FROM jobs j WHERE j.state IN ('done','skipped','failed')
                    AND NOT EXISTS(SELECT 1 FROM work_queue w WHERE w.path=j.path)
                """
            let total = try countQuery(countSQL)
            let details = """
            j.reason,j.generation,EXISTS(SELECT 1 FROM work_queue q WHERE q.path=j.path),
            (SELECT count(*) FROM chunks c WHERE c.path=j.path AND c.generation=j.generation AND c.modality='text'),
            (SELECT count(*) FROM chunks c WHERE c.path=j.path AND c.generation=j.generation AND c.modality='text' AND length(c.vector)>0),
            (SELECT count(*) FROM media_segments s JOIN media_jobs m ON m.path=s.path
                WHERE s.path=j.path AND m.generation=j.generation)
                + (SELECT count(*) FROM chunks c WHERE c.path=j.path AND c.generation=j.generation
                    AND c.modality IN ('image','audio','video')),m.audio_covered,m.video_progress
            """
            let sql = pending ? """
            SELECT w.path,w.priority,f.bytes,f.modified,j.processing_seconds,j.completed_at,j.cursor,
                COALESCE(j.state,'pending'),\(details)
            FROM work_queue w LEFT JOIN files f ON f.path=w.path LEFT JOIN jobs j ON j.path=w.path
            LEFT JOIN media_jobs m ON m.path=j.path AND m.generation=j.generation
            ORDER BY w.priority,w.turn LIMIT ? OFFSET ?
            """ : """
            SELECT j.path,-1,f.bytes,f.modified,j.processing_seconds,j.completed_at,j.cursor,j.state,\(details)
            FROM jobs j LEFT JOIN files f ON f.path=j.path
            LEFT JOIN media_jobs m ON m.path=j.path AND m.generation=j.generation
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
                var video: Double?
                if let bytes = sqlite3_column_blob(row, 15) {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 15)))
                    let progress = try? JSONDecoder().decode(SemanticVideoProgress.self, from: data)
                    if progress?.valid == true {
                        video = progress?.actual
                    }
                }
                items.append(.init(path: path, state: string(row, 7), priority: priority,
                                   bytes: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(
                                       row,
                                       2
                                   ),
                                   modified: sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                                       : Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                                   processingSeconds: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil
                                       : sqlite3_column_double(row, 4),
                                   completedAt: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil
                                       : Date(timeIntervalSince1970: sqlite3_column_double(row, 5)),
                                   page: priority == .document && (cursor?.page ?? 0) > 0 ? cursor?.page : nil,
                                   generation: sqlite3_column_type(row, 9) == SQLITE_NULL ? nil : string(row, 9),
                                   reason: sqlite3_column_type(row, 8) == SQLITE_NULL ? nil : string(row, 8),
                                   queued: pending || sqlite3_column_int(row, 10) != 0,
                                   offset: cursor?.offset ?? 0,
                                   savedChunks: Int(sqlite3_column_int(row, 11)),
                                   encodedChunks: Int(sqlite3_column_int(row, 12)),
                                   savedMediaSegments: Int(sqlite3_column_int(row, 13)),
                                   audioCovered: sqlite3_column_type(row, 14) == SQLITE_NULL ? nil
                                       : sqlite3_column_double(row, 14),
                                   videoChecked: video))
                step = sqlite3_step(row)
            }
            guard step == SQLITE_DONE else { throw Failure.database }
            return .init(items: items, total: total)
        }
        // Only the visible page is probed, without following a symlink or reading file contents.
        for index in page.items.indices where page.items[index].bytes == nil || page.items[index].modified == nil {
            var info = stat()
            guard lstat(page.items[index].path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if page.items[index].bytes == nil {
                page.items[index].bytes = Int64(info.st_size)
            }
            if page.items[index].modified == nil {
                page.items[index].modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            }
        }
        return page
    }

    /// Compare the visible selection under the queue lock; retain every checkpoint and failure reason.
    func retryProcessingItem(_ item: ProcessingItem, cancelled: () -> Bool) throws -> Bool {
        try lock.withLock {
            guard !cancelled(), item.canRetry else { return false }
            return try transaction {
                let row = try statement("SELECT state,reason,generation FROM jobs WHERE path=?")
                defer { sqlite3_finalize(row) }; bind(row, [item.path])
                guard sqlite3_step(row) == SQLITE_ROW, string(row, 2) == item.generation else { return false }
                var current = item
                current.state = string(row, 0)
                current.reason = sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : string(row, 1)
                guard current.canRetry, !cancelled() else { return false }
                try execute("INSERT OR IGNORE INTO work_queue(path,priority) VALUES(?,?)",
                            [item.path, SemanticMediaPriority.of(item.path).rawValue])
                return true
            }
        }
    }

    private func countQuery(_ sql: String) throws -> Int {
        let row = try statement(sql)
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW else { throw Failure.database }
        return Int(sqlite3_column_int64(row, 0))
    }
}
