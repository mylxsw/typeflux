import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed clipboard history at `<baseDir>/clipboard.sqlite`.
///
/// Image payloads are written as PNG files under `<baseDir>/clipboard-images/`; file payloads
/// only keep their paths, so copying a large video never duplicates it.
final class SQLiteClipboardHistoryStore: ClipboardHistoryStore {
    private let queue = DispatchQueue(label: "clipboard.history.store.sqlite")
    private let dbURL: URL
    let imagesDirectory: URL
    /// Images are the only payload stored as data, so they get a tighter cap than other items.
    let maximumImageCount: Int
    private let notificationCenter: NotificationCenter
    private var database: OpaquePointer?

    init(baseDir: URL, maximumImageCount: Int = 100, notificationCenter: NotificationCenter = .default) {
        dbURL = baseDir.appendingPathComponent("clipboard.sqlite")
        imagesDirectory = baseDir.appendingPathComponent("clipboard-images", isDirectory: true)
        self.maximumImageCount = maximumImageCount
        self.notificationCenter = notificationCenter
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        do {
            try openDatabase()
            try createSchema()
        } catch {
            ErrorLogStore.shared.log("Clipboard database initialization failed: \(error.localizedDescription)")
        }
    }

    convenience init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // The image storage limit in settings decides how much image data is kept; the count cap
        // only guards against an unlimited setting filling the list with images.
        self.init(baseDir: appSupport.appendingPathComponent("Typeflux", isDirectory: true), maximumImageCount: 1000)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    @discardableResult
    func record(_ capture: ClipboardCapture, source: ClipboardSource?, at date: Date) -> ClipboardItem? {
        let item: ClipboardItem? = queue.sync {
            do {
                return try self.insertOrBump(capture, source: source, at: date)
            } catch {
                ErrorLogStore.shared.log("Clipboard record failed: \(error.localizedDescription)")
                return nil
            }
        }
        if item != nil { notifyChange() }
        return item
    }

    func items(limit: Int) -> [ClipboardItem] {
        queue.sync {
            do {
                return try self.fetchItems(
                    sql: "SELECT \(Self.columns) FROM clipboard_items ORDER BY date DESC LIMIT ?;",
                    bind: { sqlite3_bind_int64($0, 1, Int64(max(0, limit))) }
                )
            } catch {
                ErrorLogStore.shared.log("Clipboard list failed: \(error.localizedDescription)")
                return []
            }
        }
    }

    func setPinned(_ pinned: Bool, id: UUID) {
        mutate("Clipboard pin failed") {
            try self.execute(sql: "UPDATE clipboard_items SET pinned = ? WHERE id = ?;") { statement in
                sqlite3_bind_int(statement, 1, pinned ? 1 : 0)
                self.bind(id.uuidString, at: 2, in: statement)
            }
        }
    }

    func delete(id: UUID) {
        mutate("Clipboard delete failed") {
            let removed = try self.fetchItems(
                sql: "SELECT \(Self.columns) FROM clipboard_items WHERE id = ?;",
                bind: { self.bind(id.uuidString, at: 1, in: $0) }
            )
            try self.execute(sql: "DELETE FROM clipboard_items WHERE id = ?;") { statement in
                self.bind(id.uuidString, at: 1, in: statement)
            }
            removed.forEach(self.removeImageFile(of:))
        }
    }

    func purge(olderThan cutoff: Date) {
        mutateIfChanged("Clipboard purge failed") {
            let stale = try self.fetchItems(
                sql: "SELECT \(Self.columns) FROM clipboard_items WHERE pinned = 0 AND date < ?;",
                bind: { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) }
            )
            try self.delete(stale)
            return !stale.isEmpty
        }
    }

    func trim(toMaxCount maxCount: Int) {
        mutateIfChanged("Clipboard trim failed") {
            let overflow = try self.fetchItems(
                sql: "SELECT \(Self.columns) FROM clipboard_items WHERE pinned = 0 ORDER BY date DESC LIMIT -1 OFFSET ?;",
                bind: { sqlite3_bind_int64($0, 1, Int64(max(0, maxCount))) }
            )
            try self.delete(overflow)
            let imageOverflow = try self.fetchItems(
                sql: """
                SELECT \(Self.columns) FROM clipboard_items WHERE pinned = 0 AND payload = 'image'
                ORDER BY date DESC LIMIT -1 OFFSET ?;
                """,
                bind: { sqlite3_bind_int64($0, 1, Int64(max(0, self.maximumImageCount))) }
            )
            try self.delete(imageOverflow)
            return !overflow.isEmpty || !imageOverflow.isEmpty
        }
    }

    func pinnedVoiceRecordIDs() -> Set<UUID> {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT record_id FROM clipboard_pinned_voice_records;"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            var ids = Set<UUID>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = string(at: 0, in: statement), let id = UUID(uuidString: raw) {
                    ids.insert(id)
                }
            }
            return ids
        }
    }

    func setVoiceRecordPinned(_ pinned: Bool, recordID: UUID) {
        mutate("Clipboard voice pin failed") {
            if pinned {
                try self.execute(
                    sql: "INSERT OR REPLACE INTO clipboard_pinned_voice_records (record_id, pinned_at) VALUES (?, ?);"
                ) { statement in
                    self.bind(recordID.uuidString, at: 1, in: statement)
                    sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
                }
            } else {
                try self.execute(sql: "DELETE FROM clipboard_pinned_voice_records WHERE record_id = ?;") { statement in
                    self.bind(recordID.uuidString, at: 1, in: statement)
                }
            }
        }
    }

    // MARK: - Writes

    private func insertOrBump(
        _ capture: ClipboardCapture,
        source: ClipboardSource?,
        at date: Date
    ) throws -> ClipboardItem {
        let hash = capture.contentHash
        if var existing = try fetchItems(
            sql: "SELECT \(Self.columns) FROM clipboard_items WHERE content_hash = ?;",
            bind: { self.bind(hash, at: 1, in: $0) }
        ).first {
            // Re-copying keeps the original source app: our own paste would otherwise claim it.
            try execute(sql: "UPDATE clipboard_items SET date = ? WHERE id = ?;") { statement in
                sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
                self.bind(existing.id.uuidString, at: 2, in: statement)
            }
            existing.date = date
            return existing
        }

        let id = UUID()
        var item = ClipboardItem(
            id: id, payload: .text, date: date, text: nil, filePaths: [], imagePath: nil,
            imagePixelWidth: nil, imagePixelHeight: nil, byteSize: 0, contentHash: hash,
            sourceBundleID: source?.bundleID, sourceAppName: source?.appName, isPinned: false
        )
        switch capture {
        case let .text(text):
            item.text = text
            item.byteSize = Int64(text.utf8.count)
        case let .image(png, width, height):
            let url = imagesDirectory.appendingPathComponent("\(id.uuidString).png")
            try png.write(to: url, options: .atomic)
            item.payload = .image
            item.imagePath = url.path
            item.imagePixelWidth = width
            item.imagePixelHeight = height
            item.byteSize = Int64(png.count)
        case let .files(urls):
            item.payload = .files
            item.filePaths = urls.map(\.path)
            item.byteSize = urls.reduce(0) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }

        do {
            try insert(item)
        } catch {
            removeImageFile(of: item)
            throw error
        }
        return item
    }

    private func insert(_ item: ClipboardItem) throws {
        let sql = """
        INSERT INTO clipboard_items (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try execute(sql: sql) { statement in
            self.bind(item.id.uuidString, at: 1, in: statement)
            self.bind(item.payload.rawValue, at: 2, in: statement)
            sqlite3_bind_double(statement, 3, item.date.timeIntervalSince1970)
            self.bind(item.text, at: 4, in: statement)
            self.bind(Self.encodePaths(item.filePaths), at: 5, in: statement)
            self.bind(item.imagePath, at: 6, in: statement)
            self.bind(item.imagePixelWidth, at: 7, in: statement)
            self.bind(item.imagePixelHeight, at: 8, in: statement)
            sqlite3_bind_int64(statement, 9, item.byteSize)
            self.bind(item.contentHash, at: 10, in: statement)
            self.bind(item.sourceBundleID, at: 11, in: statement)
            self.bind(item.sourceAppName, at: 12, in: statement)
            sqlite3_bind_int(statement, 13, item.isPinned ? 1 : 0)
        }
    }

    private func delete(_ items: [ClipboardItem]) throws {
        for item in items {
            try execute(sql: "DELETE FROM clipboard_items WHERE id = ?;") { statement in
                self.bind(item.id.uuidString, at: 1, in: statement)
            }
            removeImageFile(of: item)
        }
    }

    private func removeImageFile(of item: ClipboardItem) {
        guard let path = item.imagePath, path.hasPrefix(imagesDirectory.path) else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Schema

    private static let columns = """
    id, payload, date, text, file_paths, image_path, image_width, image_height, byte_size, \
    content_hash, source_bundle_id, source_app_name, pinned
    """

    private func openDatabase() throws {
        guard sqlite3_open(dbURL.path, &database) == SQLITE_OK else {
            throw databaseError(message: "Unable to open clipboard database")
        }
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
    }

    private func createSchema() throws {
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS clipboard_items (
            id TEXT PRIMARY KEY NOT NULL,
            payload TEXT NOT NULL,
            date REAL NOT NULL,
            text TEXT,
            file_paths TEXT,
            image_path TEXT,
            image_width INTEGER,
            image_height INTEGER,
            byte_size INTEGER NOT NULL DEFAULT 0,
            content_hash TEXT NOT NULL UNIQUE,
            source_bundle_id TEXT,
            source_app_name TEXT,
            pinned INTEGER NOT NULL DEFAULT 0
        );
        """)
        try execute(sql: "CREATE INDEX IF NOT EXISTS idx_clipboard_items_date ON clipboard_items(date DESC);")
        try execute(sql: """
        CREATE TABLE IF NOT EXISTS clipboard_pinned_voice_records (
            record_id TEXT PRIMARY KEY NOT NULL,
            pinned_at REAL NOT NULL
        );
        """)
    }
}

// MARK: - SQLite helpers

private extension SQLiteClipboardHistoryStore {

    func fetchItems(sql: String, bind: (OpaquePointer?) -> Void) throws -> [ClipboardItem] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare clipboard query")
        }
        bind(statement)
        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let item = decodeItem(from: statement) {
                items.append(item)
            }
        }
        return items
    }

    func decodeItem(from statement: OpaquePointer?) -> ClipboardItem? {
        guard let rawID = string(at: 0, in: statement), let id = UUID(uuidString: rawID),
              let rawPayload = string(at: 1, in: statement), let payload = ClipboardItem.Payload(rawValue: rawPayload),
              let hash = string(at: 9, in: statement)
        else { return nil }
        return ClipboardItem(
            id: id,
            payload: payload,
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            text: string(at: 3, in: statement),
            filePaths: Self.decodePaths(string(at: 4, in: statement)),
            imagePath: string(at: 5, in: statement),
            imagePixelWidth: int(at: 6, in: statement),
            imagePixelHeight: int(at: 7, in: statement),
            byteSize: sqlite3_column_int64(statement, 8),
            contentHash: hash,
            sourceBundleID: string(at: 10, in: statement),
            sourceAppName: string(at: 11, in: statement),
            isPinned: sqlite3_column_int(statement, 12) != 0
        )
    }

    func execute(sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError(message: "Failed to prepare SQL: \(sql)")
        }
        bind?(statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw databaseError(message: "Failed to execute SQL: \(sql)")
        }
    }

    func bind(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Int?, at index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func string(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: pointer)
    }

    func int(at index: Int32, in statement: OpaquePointer?) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    static func encodePaths(_ paths: [String]) -> String? {
        guard !paths.isEmpty, let data = try? JSONEncoder().encode(paths) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodePaths(_ json: String?) -> [String] {
        guard let json, let paths = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return paths
    }

    func databaseError(message: String) -> NSError {
        let detail = database.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        return NSError(domain: "SQLiteClipboardHistoryStore", code: Int(sqlite3_errcode(database)), userInfo: [
            NSLocalizedDescriptionKey: "\(message): \(detail)"
        ])
    }
}

// MARK: - Limits and bulk deletes

extension SQLiteClipboardHistoryStore {
    func deleteUnpinned(sourceBundleID: String?) {
        mutateIfChanged("Clipboard bulk delete failed") {
            // `?1 IS NULL` makes a missing app mean every app.
            let filter = "pinned = 0 AND (?1 IS NULL OR source_bundle_id = ?1)"
            let doomed = try self.fetchItems(sql: "SELECT \(Self.columns) FROM clipboard_items WHERE \(filter);") {
                self.bind(sourceBundleID, at: 1, in: $0)
            }
            try self.delete(doomed)
            return !doomed.isEmpty
        }
    }

    func trim(toMaxImageBytes maxBytes: Int64) {
        mutateIfChanged("Clipboard image trim failed") {
            let images = try self.fetchItems(
                sql: "SELECT \(Self.columns) FROM clipboard_items WHERE payload = 'image' ORDER BY date ASC;",
                bind: { _ in }
            )
            var total = images.reduce(Int64(0)) { $0 + $1.byteSize }
            var removed: [ClipboardItem] = []
            for image in images where total > max(0, maxBytes) && !image.isPinned {
                removed.append(image)
                total -= image.byteSize
            }
            try self.delete(removed)
            return !removed.isEmpty
        }
    }
}

// MARK: - Writes

private extension SQLiteClipboardHistoryStore {
    func mutate(_ failureMessage: String, _ work: @escaping () throws -> Void) {
        mutateIfChanged(failureMessage) {
            try work()
            return true
        }
    }

    /// Runs `work` on the store queue and announces a change only when it reports one, so routine
    /// purges that delete nothing don't make an open panel reload.
    func mutateIfChanged(_ failureMessage: String, _ work: @escaping () throws -> Bool) {
        let changed: Bool = queue.sync {
            do {
                return try work()
            } catch {
                ErrorLogStore.shared.log("\(failureMessage): \(error.localizedDescription)")
                return false
            }
        }
        if changed { notifyChange() }
    }

    func notifyChange() {
        let center = notificationCenter
        DispatchQueue.main.async {
            center.post(name: .clipboardHistoryDidChange, object: nil)
        }
    }
}
