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

    private struct Channel {
        var table: String
        var words: [String]
        var filter: String
    }

    struct Candidate {
        var id: Int64
        var hit: AskFileHit
        var evidence: SemanticSearchRanking.Evidence
        var bucket: SemanticScoreCalibration.Bucket
        var lexicalRank: Double
    }

    // swiftlint:disable:next function_parameter_count
    static func candidates(database: OpaquePointer, ranking: SemanticSearchRanking, query: AskSearchQuery,
                           type: AskFileType, scope: AskFileScope, limit: Int,
                           cancelled: () -> Bool) throws -> [Candidate] {
        try SemanticSQLiteCancellation.read(database, cancelled: cancelled) {
            try selectCandidates(database: database, ranking: ranking, query: query, type: type,
                                 scope: scope, limit: limit, cancelled: cancelled)
        }
    }

    // Scope and type checks precede TopK. Complete-term results precede partial matches.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    private static func selectCandidates(database: OpaquePointer, ranking: SemanticSearchRanking, query: AskSearchQuery,
                                         type: AskFileType, scope: AskFileScope, limit: Int,
                                         cancelled: () -> Bool) throws -> [Candidate] {
        guard limit > 0, !ranking.terms.isEmpty else { return [] }
        var state: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT lexical_done FROM search_migration WHERE id=1", -1, &state, nil) ==
            SQLITE_OK,
            let state else { throw SemanticFileStore.Failure.database }
        let ready = sqlite3_step(state) == SQLITE_ROW && sqlite3_column_int(state, 0) != 0
        sqlite3_finalize(state)
        let legacyTerms = Array(Set(SemanticFilePolicy.terms(ranking.originalText, legacy: true)
                .split(separator: " ").map(String.init))).sorted().prefix(64)
        // Keep the complete previous generation available while a resumable shadow build runs.
        // Old-version writes stay searchable until their dirty rows are repaired on upgrade.
        let channels: [Channel] = [
            Channel(
                table: "lexical_v4",
                words: ranking.terms,
                filter: "AND NOT EXISTS(SELECT 1 FROM search_dirty d WHERE d.id=c.id)"
            ),
            Channel(
                table: "lexical",
                words: Array(legacyTerms),
                filter: ready ? "AND EXISTS(SELECT 1 FROM search_dirty d WHERE d.id=c.id)" : ""
            )
        ]
        var best: [String: Candidate] = [:]
        for channel in channels {
            let table = channel.table, words = channel.words, filter = channel.filter
            let terms = words.map { "\"" + $0 + "\"" }
            guard !terms.isEmpty else { continue }
            for join in terms.count == 1 ? [" AND "] : [" AND ", " OR "] {
                var row: OpaquePointer?
                let sql = """
                SELECT c.id,c.path,c.text,c.page,f.modified,f.version,c.start_offset,c.end_offset,c.time,c.search_script,c.modality,rank
                FROM \(table) JOIN chunks c ON c.id=\(table).rowid JOIN files f ON f.path=c.path
                WHERE \(table) MATCH ? \(filter) ORDER BY rank,c.id
                """
                guard sqlite3_prepare_v2(database, sql, -1, &row, nil) == SQLITE_OK, let row else {
                    throw SemanticFileStore.Failure.database
                }
                defer { sqlite3_finalize(row) }
                sqlite3_bind_text(
                    row,
                    1,
                    terms.joined(separator: join),
                    -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
                func string(_ column: Int32) -> String {
                    sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
                }
                var step = sqlite3_step(row)
                while step == SQLITE_ROW {
                    guard !cancelled() else { throw CancellationError() }
                    let path = string(1)
                    if SemanticSearchRanking.allowed(path, query: query, type: type, scope: scope) {
                        let passage = string(2), evidence = ranking.evidence(passage)
                        if let score = ranking.score(
                            cosine: nil,
                            evidence: evidence,
                            modality: SemanticMediaPriority.of(path)
                        ),
                            score > (best[path]?.hit.score ?? -1) {
                            let page = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(
                                row,
                                3
                            ))
                            let rawTime = sqlite3_column_type(row, 8) == SQLITE_NULL
                                ? nil : sqlite3_column_double(row, 8)
                            let time = rawTime.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? $0 : nil }
                            let hit = AskFileHit(path: path, name: (path as NSString).lastPathComponent, kind: .file,
                                                 modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
                                                 score: score,
                                                 evidence: .init(
                                                     text: String(passage.prefix(180)),
                                                     page: page,
                                                     time: time,
                                                     version: string(5).isEmpty ? nil : string(5),
                                                     startOffset: sqlite3_column_type(row, 6) == SQLITE_NULL ?
                                                         nil : sqlite3_column_int64(
                                                             row,
                                                             6
                                                         ),
                                                     endOffset: sqlite3_column_type(row, 7) == SQLITE_NULL ?
                                                         nil : sqlite3_column_int64(
                                                             row,
                                                             7
                                                         )
                                                 ))
                            best[path] = Candidate(id: sqlite3_column_int64(row, 0), hit: hit, evidence: evidence,
                                                   bucket: .init(modality: SemanticMediaPriority.of(path),
                                                                 embedding: string(10) == "audio" ? .audio : nil,
                                                                 script: Int(sqlite3_column_int(row, 9))),
                                                   lexicalRank: sqlite3_column_double(row, 11))
                            if best.count > limit {
                                let worst = best.min {
                                    $0.value.hit.score == $1.value.hit.score
                                        ? ($0.value.lexicalRank == $1.value.lexicalRank ? $0.value.id > $1.value.id
                                            : $0.value.lexicalRank > $1.value.lexicalRank)
                                        : $0.value.hit.score < $1.value.hit.score
                                }!
                                best.removeValue(forKey: worst.key)
                            }
                        }
                    }
                    // Single-term and exact channels have a constant lexical score. Multi-term queries
                    // finish their channel so a later exact phrase can displace a scattered full match.
                    if join == " AND ", best.count >= limit,
                       terms.count == 1 || !ranking.identifiers.isEmpty || !ranking.quoted.isEmpty {
                        break
                    }
                    step = sqlite3_step(row)
                }
                guard step == SQLITE_ROW || step == SQLITE_DONE else { throw SemanticFileStore.Failure.database }
                if best.count >= limit {
                    break
                }
            }
        }
        return Array(best.values.sorted {
            $0.hit.score == $1.hit.score
                ? ($0.lexicalRank == $1.lexicalRank ? $0.id < $1.id : $0.lexicalRank < $1.lexicalRank)
                : $0.hit.score > $1.hit.score
        }.prefix(limit))
    }

    // swiftlint:disable:next function_parameter_count
    func search(text: String, query: AskSearchQuery, type: AskFileType, scope: AskFileScope,
                limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        guard limit > 0, !SemanticFilePolicy.searchTerms(text).isEmpty else { return [] }
        let waiting = ProcessInfo.processInfo.systemUptime
        return try lock.withLock {
            SemanticSearchTrace.current?.measure("fts-lock-wait",
                                                 milliseconds: (ProcessInfo.processInfo.systemUptime - waiting) * 1000)
            guard !cancelled() else { throw CancellationError() }
            guard let database else { throw SemanticFileStore.Failure.database }
            return try Self.candidates(database: database, ranking: SemanticSearchRanking(text), query: query,
                                       type: type, scope: scope, limit: min(100, limit), cancelled: cancelled)
                .map(\.hit)
        }
    }
}
