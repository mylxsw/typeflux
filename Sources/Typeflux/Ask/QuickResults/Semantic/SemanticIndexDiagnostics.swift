import CryptoKit
import Foundation
import SQLite3

/// Exportable diagnostics contain fixed reason codes, opaque generations and counters, never paths/content.
struct SemanticIndexDiagnostics: Codable, Equatable, Sendable {
    enum Reason: String, Codable,
        Sendable { case startup, configuration, resume, filesystem, rebuild, retry, modelInstalled }
    enum Stage: String, Codable,
        Sendable { case checking, scanning, incremental, tail, extracting, encoding, migration, waiting, complete,
                    failed, cancelled
    }

    enum Counter: String, CaseIterable, Codable, Sendable {
        case scanned, metadataReused, tailBatches, extractionBatches, ftsChunks, vectorReusedFiles
        case vectorReusedSegments, encodingRequests, vectorsInferred, vectorsPublished, retries, failures
        case eventTasks, subtreeScans, migrationRows, budgetYields, budgetWaitMilliseconds, budgetInterruptions
    }

    var id: String
    var reason: Reason
    var stage: Stage
    var started: Date
    var finished: Date?
    var configurationGeneration: String
    var modelGeneration: String
    var extractionGeneration: String
    var applicationVersion: String
    var counters: [String: Int]
}

extension SemanticFileStore {
    func prepareDiagnosticsSchema() throws {
        let columns = SemanticIndexDiagnostics.Counter.allCases.map { "\($0.rawValue) INTEGER NOT NULL DEFAULT 0" }
        try sql("""
        CREATE TABLE IF NOT EXISTS index_runs(
            id TEXT PRIMARY KEY,reason TEXT NOT NULL,stage TEXT NOT NULL,started REAL NOT NULL,finished REAL,
            configuration TEXT NOT NULL,model TEXT NOT NULL,recipe TEXT NOT NULL,application TEXT NOT NULL,
            \(columns.joined(separator: ",")));
        """)
        try sql("CREATE INDEX IF NOT EXISTS index_run_started ON index_runs(started DESC)")
        for counter in SemanticIndexDiagnostics.Counter.allCases {
            try addColumn("index_runs", name: counter.rawValue, declaration: "INTEGER NOT NULL DEFAULT 0")
        }
    }

    func beginRun(reason: SemanticIndexDiagnostics.Reason, configuration: String) throws {
        try lock.withLock {
            let generation = SHA256.hash(data: Data(configuration.utf8)).map { String(format: "%02x", $0) }.joined()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            let id = UUID().uuidString
            try execute("""
            INSERT INTO index_runs(id,reason,stage,started,configuration,model,recipe,application)
            VALUES(?,?,'checking',?,?,?,?,?)
            """, [id, reason.rawValue, Date().timeIntervalSince1970, generation,
                  SemanticFilePolicy.profile,
                  Self.documentProvenance + ";" + SemanticPDFText.recipe + ";"
                      + SemanticWordText.recipe + ";" + SemanticHTMLText.recipe + ";"
                      + SemanticRTFText.recipe + ";" + SemanticODTText.recipe + ";" + Self.mediaProvenance,
                  version + " (" + build + ")"])
            activeRunID = id
            try execute(
                """
                DELETE FROM index_runs WHERE id IN (SELECT id FROM index_runs ORDER BY started DESC LIMIT -1 OFFSET 32)
                """,
                []
            )
        }
    }

    func record(_ counter: SemanticIndexDiagnostics.Counter, count: Int = 1) throws {
        try lock.withLock { try recordLocked(counter, count: count) }
    }

    /// Join the caller's content/checkpoint transaction so rollback cannot invent committed work.
    func recordLocked(_ counter: SemanticIndexDiagnostics.Counter, count: Int = 1) throws {
        guard let activeRunID, count > 0 else { return }
        try execute("UPDATE index_runs SET \(counter.rawValue)=\(counter.rawValue)+? WHERE id=?", [count, activeRunID])
    }

    func setStage(_ stage: SemanticIndexDiagnostics.Stage) throws {
        try lock.withLock {
            guard let activeRunID else { return }
            try execute(
                "UPDATE index_runs SET stage=? WHERE id=? AND stage<>?",
                [stage.rawValue, activeRunID, stage.rawValue]
            )
        }
    }

    func finishRun(stage: SemanticIndexDiagnostics.Stage) throws {
        try lock.withLock {
            guard let activeRunID else { return }
            try execute("UPDATE index_runs SET stage=?,finished=? WHERE id=?",
                        [stage.rawValue, Date().timeIntervalSince1970, activeRunID])
        }
    }

    func runDiagnostics() throws -> SemanticIndexDiagnostics? {
        try lock.withLock {
            let counters = SemanticIndexDiagnostics.Counter.allCases
            let selection = activeRunID == nil ? "ORDER BY started DESC LIMIT 1" : "WHERE id=?"
            let row = try statement("""
            SELECT id,reason,stage,started,finished,configuration,model,recipe,application,\(counters.map(\.rawValue).joined(separator: ","))
            FROM index_runs \(selection)
            """)
            defer { sqlite3_finalize(row) }
            if let activeRunID {
                bind(row, [activeRunID])
            }
            let step = sqlite3_step(row)
            if step == SQLITE_DONE {
                return nil
            }
            guard step == SQLITE_ROW, let reason = SemanticIndexDiagnostics.Reason(rawValue: string(row, 1)),
                  let stage = SemanticIndexDiagnostics.Stage(rawValue: string(row, 2)) else { throw Failure.database }
            return .init(id: string(row, 0), reason: reason, stage: stage,
                         started: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)),
                         finished: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil :
                             Date(timeIntervalSince1970: sqlite3_column_double(
                                 row,
                                 4
                             )),
                         configurationGeneration: string(row, 5), modelGeneration: string(row, 6),
                         extractionGeneration: string(
                             row,
                             7
                         ),
                         applicationVersion: string(row, 8),
                         counters: Dictionary(uniqueKeysWithValues: counters.enumerated().map {
                             ($0.element.rawValue, Int(sqlite3_column_int64(row, Int32($0.offset + 9))))
                         }))
        }
    }
}

extension SemanticFileStore {
    func updateBudget(_ value: SemanticWorkBudget.Statistics, since start: SemanticWorkBudget.Statistics) throws {
        try lock.withLock {
            guard let activeRunID else { return }
            try execute(
                "UPDATE index_runs SET budgetYields=?,budgetWaitMilliseconds=?,budgetInterruptions=? WHERE id=?",
                [value.yields - start.yields, value.milliseconds - start.milliseconds,
                 value.interruptions - start.interruptions, activeRunID]
            )
        }
    }
}
