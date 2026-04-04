import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteHistoryStore: HistoryStore {
    private let queue = DispatchQueue(label: "history.store.sqlite")

    private let baseDir: URL
    private let dbURL: URL
    private let legacyIndexURL: URL
    private var db: OpaquePointer?

    init(baseDir: URL) {
        self.baseDir = baseDir
        self.dbURL = baseDir.appendingPathComponent("history.sqlite")
        self.legacyIndexURL = baseDir.appendingPathComponent("history.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        do {
            try openDatabase()
            try createSchema()
            try migrateSchemaIfNeeded()
            try migrateLegacyJSONIfNeeded()
        } catch {
            ErrorLogStore.shared.log("History database initialization failed: \(error.localizedDescription)")
        }
    }

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newBaseDir = appSupport.appendingPathComponent("Typeflux", isDirectory: true)
        let legacyBaseDir = appSupport.appendingPathComponent("Typeflux", isDirectory: true)
        if !FileManager.default.fileExists(atPath: newBaseDir.path),
           FileManager.default.fileExists(atPath: legacyBaseDir.path) {
            try? FileManager.default.moveItem(at: legacyBaseDir, to: newBaseDir)
        }
        self.init(baseDir: newBaseDir)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func save(record: HistoryRecord) {
        queue.async {
            do {
                try self.upsert(record: record)
                self.notifyChange()
            } catch {
                ErrorLogStore.shared.log("History save failed: \(error.localizedDescription)")
            }
        }
    }

    func list() -> [HistoryRecord] {
        queue.sync {
            do {
                return try self.fetchAll()
            } catch {
                ErrorLogStore.shared.log("History list failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    func list(limit: Int, offset: Int, searchQuery: String?) -> [HistoryRecord] {
        queue.sync {
            do {
                return try self.fetchPage(limit: limit, offset: offset, searchQuery: searchQuery)
            } catch {
                ErrorLogStore.shared.log("History paged list failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    func record(id: UUID) -> HistoryRecord? {
        queue.sync {
            do {
                return try self.fetchRecord(id: id)
            } catch {
                ErrorLogStore.shared.log("History lookup failed: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func delete(id: UUID) {
        queue.async {
            do {
                let audioPath = try self.fetchAudioPath(id: id)
                try self.execute(
                    sql: "DELETE FROM history_records WHERE id = ?;",
                    bind: { statement in
                        self.bind(id.uuidString, at: 1, in: statement)
                    }
                )
                if let audioPath {
                    self.removeAudioFileIfNeeded(at: audioPath)
                }
                self.notifyChange()
            } catch {
                ErrorLogStore.shared.log("History delete failed: \(error.localizedDescription)")
            }
        }
    }

    func purge(olderThanDays days: Int) {
        queue.async {
            do {
                let cutoff = Date().addingTimeInterval(-TimeInterval(days) * 24 * 3600)
                let staleAudioPaths = try self.fetchAudioPaths(olderThan: cutoff)
                try self.execute(
                    sql: "DELETE FROM history_records WHERE date < ?;",
                    bind: { statement in
                        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
                    }
                )
                staleAudioPaths.forEach(self.removeAudioFileIfNeeded(at:))
                self.notifyChange()
            } catch {
                ErrorLogStore.shared.log("History purge failed: \(error.localizedDescription)")
            }
        }
    }

    func clear() {
        queue.async {
            do {
                let audioPaths = try self.fetchAllAudioPaths()
                try self.execute(sql: "DELETE FROM history_records;")
                audioPaths.forEach(self.removeAudioFileIfNeeded(at:))
                self.notifyChange()
            } catch {
                ErrorLogStore.shared.log("History clear failed: \(error.localizedDescription)")
            }
        }
    }

    func exportMarkdown() throws -> URL {
        let records = list()
        let dateFmt = ISO8601DateFormatter()

        var md = "# Typeflux History\n\n"
        for r in records {
            md += "## \(dateFmt.string(from: r.date))\n\n"
            md += "- Mode: \(r.mode.rawValue)\n"
            md += "- Recording: \(r.recordingStatus.rawValue)\n"
            md += "- Transcription: \(r.transcriptionStatus.rawValue)\n"
            md += "- Processing: \(r.processingStatus.rawValue)\n"
            md += "- Apply: \(r.applyStatus.rawValue)\n"
            if let audioFilePath = r.audioFilePath {
                md += "- Audio: \(audioFilePath)\n"
            }
            if let transcriptText = r.transcriptText, !transcriptText.isEmpty {
                md += "\n### Transcript\n\n\(transcriptText)\n"
            }
            if let pipelineTiming = r.pipelineTiming, pipelineTiming.hasData {
                let pipelineStats = r.pipelineStats ?? pipelineTiming.generatedStats()
                md += "\n### Pipeline Stats\n\n\(markdown(for: pipelineStats))\n"
            } else if let pipelineStats = r.pipelineStats, pipelineStats.hasData {
                md += "\n### Pipeline Stats\n\n\(markdown(for: pipelineStats))\n"
            }
            if let personaResultText = r.personaResultText, !personaResultText.isEmpty {
                md += "\n### Persona Result\n\n\(personaResultText)\n"
            }
            if let selectionOriginalText = r.selectionOriginalText, !selectionOriginalText.isEmpty {
                md += "\n### Selected Text\n\n\(selectionOriginalText)\n"
            }
            if let selectionEditedText = r.selectionEditedText, !selectionEditedText.isEmpty {
                md += "\n### Selection Result\n\n\(selectionEditedText)\n"
            }
            if let errorMessage = r.errorMessage, !errorMessage.isEmpty {
                md += "\n### Error\n\n\(errorMessage)\n"
            }
            md += "\n\n"
        }

        let url = baseDir.appendingPathComponent("history-\(Int(Date().timeIntervalSince1970)).md")
        try md.data(using: .utf8)?.write(to: url)
        return url
    }

    private func openDatabase() throws {
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw databaseError(message: "Unable to open SQLite database")
        }

        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA temp_store = MEMORY;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    private func createSchema() throws {
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS history_records (
            id TEXT PRIMARY KEY NOT NULL,
            date REAL NOT NULL,
            mode TEXT NOT NULL,
            audio_file_path TEXT,
            transcript_text TEXT,
            persona_prompt TEXT,
            persona_result_text TEXT,
            selection_original_text TEXT,
            selection_edited_text TEXT,
            recording_duration_seconds REAL,
            pipeline_timing_json TEXT,
            pipeline_stats_json TEXT,
            error_message TEXT,
            apply_message TEXT,
            recording_status TEXT NOT NULL,
            transcription_status TEXT NOT NULL,
            processing_status TEXT NOT NULL,
            apply_status TEXT NOT NULL
        );
        """

        try execute(sql: createTableSQL)
        try execute(sql: "CREATE INDEX IF NOT EXISTS idx_history_records_date ON history_records(date DESC);")
    }

    private func migrateSchemaIfNeeded() throws {
        try ensureColumnExists(name: "pipeline_timing_json", definition: "TEXT")
        try ensureColumnExists(name: "pipeline_stats_json", definition: "TEXT")
    }

    private func migrateLegacyJSONIfNeeded() throws {
        guard try rowCount() == 0 else { return }
        guard let data = try? Data(contentsOf: legacyIndexURL) else { return }
        let records = (try? JSONDecoder().decode([HistoryRecord].self, from: data)) ?? []
        guard !records.isEmpty else { return }

        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            for record in records {
                try upsert(record: record)
            }
            try execute(sql: "COMMIT;")
        } catch {
            _ = try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    private func rowCount() throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history_records;", -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare row count query")
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw databaseError(message: "Failed to read row count")
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fetchAll() throws -> [HistoryRecord] {
        try fetchRecords(
            sql: """
            SELECT id, date, mode, audio_file_path, transcript_text, persona_prompt, persona_result_text,
                   selection_original_text, selection_edited_text, recording_duration_seconds, pipeline_timing_json, pipeline_stats_json,
                   error_message, apply_message, recording_status, transcription_status, processing_status, apply_status
            FROM history_records
            ORDER BY date DESC;
            """
        )
    }

    private func fetchPage(limit: Int, offset: Int, searchQuery: String?) throws -> [HistoryRecord] {
        let trimmedQuery = searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedQuery.isEmpty {
            return try fetchRecords(
                sql: """
                SELECT id, date, mode, audio_file_path, transcript_text, persona_prompt, persona_result_text,
                       selection_original_text, selection_edited_text, recording_duration_seconds, pipeline_timing_json, pipeline_stats_json,
                       error_message, apply_message, recording_status, transcription_status, processing_status, apply_status
                FROM history_records
                ORDER BY date DESC
                LIMIT ? OFFSET ?;
                """,
                bind: { statement in
                    sqlite3_bind_int64(statement, 1, sqlite3_int64(limit))
                    sqlite3_bind_int64(statement, 2, sqlite3_int64(offset))
                }
            )
        }

        let wildcardQuery = "%\(trimmedQuery)%"
        return try fetchRecords(
            sql: """
            SELECT id, date, mode, audio_file_path, transcript_text, persona_prompt, persona_result_text,
                   selection_original_text, selection_edited_text, recording_duration_seconds, pipeline_timing_json, pipeline_stats_json,
                   error_message, apply_message, recording_status, transcription_status, processing_status, apply_status
            FROM history_records
            WHERE mode LIKE ? COLLATE NOCASE
               OR transcript_text LIKE ? COLLATE NOCASE
               OR persona_result_text LIKE ? COLLATE NOCASE
               OR selection_edited_text LIKE ? COLLATE NOCASE
               OR error_message LIKE ? COLLATE NOCASE
               OR audio_file_path LIKE ? COLLATE NOCASE
            ORDER BY date DESC
            LIMIT ? OFFSET ?;
            """,
            bind: { statement in
                self.bind(wildcardQuery, at: 1, in: statement)
                self.bind(wildcardQuery, at: 2, in: statement)
                self.bind(wildcardQuery, at: 3, in: statement)
                self.bind(wildcardQuery, at: 4, in: statement)
                self.bind(wildcardQuery, at: 5, in: statement)
                self.bind(wildcardQuery, at: 6, in: statement)
                sqlite3_bind_int64(statement, 7, sqlite3_int64(limit))
                sqlite3_bind_int64(statement, 8, sqlite3_int64(offset))
            }
        )
    }

    private func fetchRecord(id: UUID) throws -> HistoryRecord? {
        try fetchRecords(
            sql: """
            SELECT id, date, mode, audio_file_path, transcript_text, persona_prompt, persona_result_text,
                   selection_original_text, selection_edited_text, recording_duration_seconds, pipeline_timing_json, pipeline_stats_json,
                   error_message, apply_message, recording_status, transcription_status, processing_status, apply_status
            FROM history_records
            WHERE id = ?
            LIMIT 1;
            """,
            bind: { statement in
                self.bind(id.uuidString, at: 1, in: statement)
            }
        ).first
    }

    private func fetchRecords(
        sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) throws -> [HistoryRecord] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare history query")
        }

        bind?(statement)

        var records: [HistoryRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            records.append(try decodeRecord(from: statement))
        }
        return records
    }

    private func upsert(record: HistoryRecord) throws {
        let sql = """
        INSERT INTO history_records (
            id, date, mode, audio_file_path, transcript_text, persona_prompt, persona_result_text,
            selection_original_text, selection_edited_text, recording_duration_seconds, pipeline_timing_json, pipeline_stats_json,
            error_message, apply_message, recording_status, transcription_status, processing_status, apply_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            date = excluded.date,
            mode = excluded.mode,
            audio_file_path = excluded.audio_file_path,
            transcript_text = excluded.transcript_text,
            persona_prompt = excluded.persona_prompt,
            persona_result_text = excluded.persona_result_text,
            selection_original_text = excluded.selection_original_text,
            selection_edited_text = excluded.selection_edited_text,
            recording_duration_seconds = excluded.recording_duration_seconds,
            pipeline_timing_json = excluded.pipeline_timing_json,
            pipeline_stats_json = excluded.pipeline_stats_json,
            error_message = excluded.error_message,
            apply_message = excluded.apply_message,
            recording_status = excluded.recording_status,
            transcription_status = excluded.transcription_status,
            processing_status = excluded.processing_status,
            apply_status = excluded.apply_status;
        """

        try execute(sql: sql) { statement in
            self.bind(record.id.uuidString, at: 1, in: statement)
            sqlite3_bind_double(statement, 2, record.date.timeIntervalSince1970)
            self.bind(record.mode.rawValue, at: 3, in: statement)
            self.bind(record.audioFilePath, at: 4, in: statement)
            self.bind(record.transcriptText, at: 5, in: statement)
            self.bind(record.personaPrompt, at: 6, in: statement)
            self.bind(record.personaResultText, at: 7, in: statement)
            self.bind(record.selectionOriginalText, at: 8, in: statement)
            self.bind(record.selectionEditedText, at: 9, in: statement)
            self.bind(record.recordingDurationSeconds, at: 10, in: statement)
            self.bind(self.encodeCodable(record.pipelineTiming), at: 11, in: statement)
            self.bind(self.encodeCodable(record.pipelineStats ?? record.pipelineTiming?.generatedStats()), at: 12, in: statement)
            self.bind(record.errorMessage, at: 13, in: statement)
            self.bind(record.applyMessage, at: 14, in: statement)
            self.bind(record.recordingStatus.rawValue, at: 15, in: statement)
            self.bind(record.transcriptionStatus.rawValue, at: 16, in: statement)
            self.bind(record.processingStatus.rawValue, at: 17, in: statement)
            self.bind(record.applyStatus.rawValue, at: 18, in: statement)
        }
    }

    private func fetchAudioPath(id: UUID) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "SELECT audio_file_path FROM history_records WHERE id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare audio path query")
        }

        bind(id.uuidString, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return string(at: 0, in: statement)
    }

    private func fetchAudioPaths(olderThan cutoff: Date) throws -> [String] {
        try fetchAudioPaths(
            sql: "SELECT audio_file_path FROM history_records WHERE date < ? AND audio_file_path IS NOT NULL;",
            bind: { statement in
                sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            }
        )
    }

    private func fetchAllAudioPaths() throws -> [String] {
        try fetchAudioPaths(sql: "SELECT audio_file_path FROM history_records WHERE audio_file_path IS NOT NULL;")
    }

    private func fetchAudioPaths(
        sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare audio path list query")
        }

        bind?(statement)

        var paths: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let path = string(at: 0, in: statement), !path.isEmpty {
                paths.append(path)
            }
        }
        return paths
    }

    private func decodeRecord(from statement: OpaquePointer?) throws -> HistoryRecord {
        guard
            let idString = string(at: 0, in: statement),
            let id = UUID(uuidString: idString),
            let modeRaw = string(at: 2, in: statement),
            let mode = HistoryRecord.Mode(rawValue: modeRaw),
            let recordingStatusRaw = string(at: 14, in: statement),
            let recordingStatus = HistoryRecord.StepStatus(rawValue: recordingStatusRaw),
            let transcriptionStatusRaw = string(at: 15, in: statement),
            let transcriptionStatus = HistoryRecord.StepStatus(rawValue: transcriptionStatusRaw),
            let processingStatusRaw = string(at: 16, in: statement),
            let processingStatus = HistoryRecord.StepStatus(rawValue: processingStatusRaw),
            let applyStatusRaw = string(at: 17, in: statement),
            let applyStatus = HistoryRecord.StepStatus(rawValue: applyStatusRaw)
        else {
            throw databaseError(message: "History database returned invalid record data")
        }

        return HistoryRecord(
            id: id,
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            mode: mode,
            audioFilePath: string(at: 3, in: statement),
            transcriptText: string(at: 4, in: statement),
            personaPrompt: string(at: 5, in: statement),
            personaResultText: string(at: 6, in: statement),
            selectionOriginalText: string(at: 7, in: statement),
            selectionEditedText: string(at: 8, in: statement),
            recordingDurationSeconds: double(at: 9, in: statement),
            pipelineTiming: decodeCodable(from: string(at: 10, in: statement), as: HistoryPipelineTiming.self),
            pipelineStats: decodeCodable(from: string(at: 11, in: statement), as: HistoryPipelineStats.self),
            errorMessage: string(at: 12, in: statement),
            applyMessage: string(at: 13, in: statement),
            recordingStatus: recordingStatus,
            transcriptionStatus: transcriptionStatus,
            processingStatus: processingStatus,
            applyStatus: applyStatus
        )
    }

    private func execute(
        sql: String,
        bind: ((OpaquePointer?) -> Void)? = nil
    ) throws {
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

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_double(statement, index, value)
    }

    private func string(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func double(at index: Int32, in statement: OpaquePointer?) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func ensureColumnExists(name: String, definition: String) throws {
        guard !hasColumn(named: name) else { return }
        try execute(sql: "ALTER TABLE history_records ADD COLUMN \(name) \(definition);")
    }

    private func hasColumn(named name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "PRAGMA table_info(history_records);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let columnName = string(at: 1, in: statement), columnName == name {
                return true
            }
        }

        return false
    }

    private func encodeCodable<T: Codable>(_ value: T?) -> String? {
        guard let value else { return nil }
        if let timing = value as? HistoryPipelineTiming, !timing.hasData {
            return nil
        }
        if let stats = value as? HistoryPipelineStats, !stats.hasData {
            return nil
        }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeCodable<T: Decodable>(from json: String?, as type: T.Type) -> T? {
        guard let json, !json.isEmpty else { return nil }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func markdown(for stats: HistoryPipelineStats) -> String {
        var lines: [String] = []

        if let value = stats.recordingStoppedAt {
            lines.append("- Recording stopped: \(value.ISO8601Format())")
        }
        if let value = stats.audioFileReadyAt {
            lines.append("- Audio file ready: \(value.ISO8601Format())")
        }
        if let value = stats.transcriptionStartedAt {
            lines.append("- STT started: \(value.ISO8601Format())")
        }
        if let value = stats.transcriptionCompletedAt {
            lines.append("- STT completed: \(value.ISO8601Format())")
        }
        if let value = stats.llmProcessingStartedAt {
            lines.append("- LLM started: \(value.ISO8601Format())")
        }
        if let value = stats.llmProcessingCompletedAt {
            lines.append("- LLM completed: \(value.ISO8601Format())")
        }
        if let value = stats.applyStartedAt {
            lines.append("- Apply started: \(value.ISO8601Format())")
        }
        if let value = stats.applyCompletedAt {
            lines.append("- Apply completed: \(value.ISO8601Format())")
        }

        let durations: [(String, Int?)] = [
            ("Stop -> audio ready", stats.stopToAudioReadyMilliseconds),
            ("STT duration", stats.transcriptionDurationMilliseconds),
            ("Stop -> STT completed", stats.stopToTranscriptionCompletedMilliseconds),
            ("Transcript -> LLM start", stats.transcriptToLLMStartMilliseconds),
            ("LLM duration", stats.llmDurationMilliseconds),
            ("Apply duration", stats.applyDurationMilliseconds),
            ("End-to-end", stats.endToEndMilliseconds)
        ]

        for (label, value) in durations {
            if let value {
                lines.append("- \(label): \(value) ms")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        }
    }

    private func removeAudioFileIfNeeded(at path: String) {
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func databaseError(message: String) -> NSError {
        let detail = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        let code = db.map { sqlite3_errcode($0) } ?? SQLITE_ERROR
        return NSError(domain: "SQLiteHistoryStore", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(detail)"
        ])
    }
}
