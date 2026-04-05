import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Notification posted when the agent job store changes.
extension Notification.Name {
    static let agentJobStoreDidChange = Notification.Name("agentJobStoreDidChange")
}

/// SQLite-backed persistent storage for agent jobs.
final class SQLiteAgentJobStore: AgentJobStore, @unchecked Sendable {
    private let queue = DispatchQueue(label: "agent.job.store.sqlite")
    private let dbURL: URL
    private var db: OpaquePointer?

    init(baseDir: URL) {
        dbURL = baseDir.appendingPathComponent("agent_jobs.sqlite")
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        do {
            try openDatabase()
            try createSchema()
        } catch {
            ErrorLogStore.shared.log("Agent job database initialization failed: \(error.localizedDescription)")
        }
    }

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Typeflux", isDirectory: true)
        self.init(baseDir: baseDir)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - AgentJobStore

    func save(_ job: AgentJob) async throws {
        try queue.sync {
            try self.upsert(job: job)
            self.notifyChange()
        }
    }

    func list(limit: Int, offset: Int) async throws -> [AgentJob] {
        try queue.sync {
            try self.fetchPage(limit: limit, offset: offset)
        }
    }

    func job(id: UUID) async throws -> AgentJob? {
        try queue.sync {
            try self.fetchOne(id: id)
        }
    }

    func delete(id: UUID) async throws {
        try queue.sync {
            try self.execute(sql: "DELETE FROM agent_jobs WHERE id = ?;") { statement in
                self.bind(id.uuidString, at: 1, in: statement)
            }
            self.notifyChange()
        }
    }

    func clear() async throws {
        try queue.sync {
            try self.execute(sql: "DELETE FROM agent_jobs;")
            self.notifyChange()
        }
    }

    func count() async throws -> Int {
        try queue.sync {
            try self.rowCount()
        }
    }

    // MARK: - Database Setup

    private func openDatabase() throws {
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw databaseError(message: "Unable to open agent jobs database")
        }
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA temp_store = MEMORY;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    private func createSchema() throws {
        try execute(sql: """
            CREATE TABLE IF NOT EXISTS agent_jobs (
                id TEXT PRIMARY KEY NOT NULL,
                created_at REAL NOT NULL,
                completed_at REAL,
                status TEXT NOT NULL,
                title TEXT,
                user_prompt TEXT NOT NULL,
                selected_text TEXT,
                result_text TEXT,
                error_message TEXT,
                steps_json TEXT,
                total_duration_ms INTEGER,
                outcome_type TEXT,
                total_prompt_tokens INTEGER,
                total_completion_tokens INTEGER,
                total_tokens INTEGER
            );
        """)
        try execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_jobs_created_at ON agent_jobs(created_at DESC);")
        // Migrate existing databases that lack the token columns.
        try migrateAddTokenColumns()
    }

    private func migrateAddTokenColumns() throws {
        // Query existing columns; skip ALTER TABLE if they already exist.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(agent_jobs);", -1, &statement, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(statement) }

        var existingColumns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(statement, 1) {
                existingColumns.insert(String(cString: namePtr))
            }
        }

        let newColumns = [
            ("total_prompt_tokens", "INTEGER"),
            ("total_completion_tokens", "INTEGER"),
            ("total_tokens", "INTEGER"),
        ]
        for (column, type) in newColumns where !existingColumns.contains(column) {
            try? execute(sql: "ALTER TABLE agent_jobs ADD COLUMN \(column) \(type);")
        }
    }

    // MARK: - CRUD

    private func upsert(job: AgentJob) throws {
        let sql = """
            INSERT INTO agent_jobs (
                id, created_at, completed_at, status, title, user_prompt, selected_text,
                result_text, error_message, steps_json, total_duration_ms, outcome_type,
                total_prompt_tokens, total_completion_tokens, total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                created_at = excluded.created_at,
                completed_at = excluded.completed_at,
                status = excluded.status,
                title = excluded.title,
                user_prompt = excluded.user_prompt,
                selected_text = excluded.selected_text,
                result_text = excluded.result_text,
                error_message = excluded.error_message,
                steps_json = excluded.steps_json,
                total_duration_ms = excluded.total_duration_ms,
                outcome_type = excluded.outcome_type,
                total_prompt_tokens = excluded.total_prompt_tokens,
                total_completion_tokens = excluded.total_completion_tokens,
                total_tokens = excluded.total_tokens;
        """

        try execute(sql: sql) { statement in
            self.bind(job.id.uuidString, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, job.createdAt.timeIntervalSince1970)
            if let completedAt = job.completedAt {
                sqlite3_bind_double(statement, 3, completedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            self.bind(job.status.rawValue, at: 4, in: statement)
            self.bind(job.title, at: 5, in: statement)
            self.bind(job.userPrompt, at: 6, in: statement)
            self.bind(job.selectedText, at: 7, in: statement)
            self.bind(job.resultText, at: 8, in: statement)
            self.bind(job.errorMessage, at: 9, in: statement)
            self.bind(self.encodeSteps(job.steps), at: 10, in: statement)
            if let duration = job.totalDurationMs {
                sqlite3_bind_int64(statement, 11, sqlite3_int64(duration))
            } else {
                sqlite3_bind_null(statement, 11)
            }
            self.bind(job.outcomeType, at: 12, in: statement)
            if let usage = job.totalTokenUsage {
                sqlite3_bind_int64(statement, 13, sqlite3_int64(usage.promptTokens))
                sqlite3_bind_int64(statement, 14, sqlite3_int64(usage.completionTokens))
                sqlite3_bind_int64(statement, 15, sqlite3_int64(usage.totalTokens))
            } else {
                sqlite3_bind_null(statement, 13)
                sqlite3_bind_null(statement, 14)
                sqlite3_bind_null(statement, 15)
            }
        }
    }

    private func fetchPage(limit: Int, offset: Int) throws -> [AgentJob] {
        try fetchJobs(
            sql: """
                SELECT id, created_at, completed_at, status, title, user_prompt, selected_text,
                       result_text, error_message, steps_json, total_duration_ms, outcome_type,
                       total_prompt_tokens, total_completion_tokens, total_tokens
                FROM agent_jobs
                ORDER BY created_at DESC
                LIMIT ? OFFSET ?;
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, sqlite3_int64(limit))
                sqlite3_bind_int64(statement, 2, sqlite3_int64(offset))
            },
        )
    }

    private func fetchOne(id: UUID) throws -> AgentJob? {
        try fetchJobs(
            sql: """
                SELECT id, created_at, completed_at, status, title, user_prompt, selected_text,
                       result_text, error_message, steps_json, total_duration_ms, outcome_type,
                       total_prompt_tokens, total_completion_tokens, total_tokens
                FROM agent_jobs
                WHERE id = ?
                LIMIT 1;
            """,
            bind: { statement in
                self.bind(id.uuidString, at: 1, in: statement)
            },
        ).first
    }

    private func fetchJobs(
        sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil,
    ) throws -> [AgentJob] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare agent jobs query")
        }

        bind?(statement)

        var jobs: [AgentJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try jobs.append(decodeJob(from: statement))
        }
        return jobs
    }

    private func rowCount() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM agent_jobs;", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare count query")
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(message: "Failed to read count")
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Decoding

    private func decodeJob(from statement: OpaquePointer?) throws -> AgentJob {
        guard
            let idString = string(at: 0, in: statement),
            let id = UUID(uuidString: idString),
            let statusRaw = string(at: 3, in: statement),
            let status = AgentJobStatus(rawValue: statusRaw),
            let userPrompt = string(at: 5, in: statement)
        else {
            throw databaseError(message: "Agent job database returned invalid record data")
        }

        let completedAtRaw = sqlite3_column_type(statement, 2) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            : nil

        let totalDurationMs: Int64? = sqlite3_column_type(statement, 10) != SQLITE_NULL
            ? sqlite3_column_int64(statement, 10)
            : nil

        // Columns 12, 13, 14: total_prompt_tokens, total_completion_tokens, total_tokens
        let totalTokenUsage: LLMTokenUsage? = {
            guard sqlite3_column_type(statement, 14) != SQLITE_NULL else { return nil }
            let prompt = Int(sqlite3_column_int64(statement, 12))
            let completion = Int(sqlite3_column_int64(statement, 13))
            let total = Int(sqlite3_column_int64(statement, 14))
            return LLMTokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total,
            )
        }()

        return AgentJob(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            completedAt: completedAtRaw,
            status: status,
            title: string(at: 4, in: statement),
            userPrompt: userPrompt,
            selectedText: string(at: 6, in: statement),
            resultText: string(at: 7, in: statement),
            errorMessage: string(at: 8, in: statement),
            steps: decodeSteps(from: string(at: 9, in: statement)),
            totalDurationMs: totalDurationMs,
            outcomeType: string(at: 11, in: statement),
            totalTokenUsage: totalTokenUsage,
        )
    }

    // MARK: - Helpers

    private func execute(sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare SQL: \(sql)")
        }

        bind?(statement)

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw databaseError(message: "Failed to execute SQL: \(sql)")
        }
    }

    private func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func string(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index)
        else {
            return nil
        }
        return String(cString: value)
    }

    private func encodeSteps(_ steps: [AgentJobStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(steps) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeSteps(from json: String?) -> [AgentJobStep] {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AgentJobStep].self, from: data)) ?? []
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .agentJobStoreDidChange, object: nil)
        }
    }

    private func databaseError(message: String) -> NSError {
        let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        let code = db.map { sqlite3_errcode($0) } ?? SQLITE_ERROR
        return NSError(domain: "SQLiteAgentJobStore", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(detail)",
        ])
    }
}
