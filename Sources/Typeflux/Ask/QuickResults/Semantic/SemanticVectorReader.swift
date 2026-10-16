// swiftlint:disable file_length
// Connection/cache and lifecycle ownership remain private to this implementation.
import Accelerate
import Foundation
import SQLite3

// Search owns a read connection and immutable 256-row pages. A committed dirty page is replaced atomically;
// deleted IDs and same-ID replacements cannot survive the revision check. No index-writer lock is acquired.
// swiftlint:disable:next type_body_length
final class SemanticVectorReader: @unchecked Sendable {
    private final class File {
        let path: String
        let modified: Date
        let version: String?
        let modality: SemanticMediaPriority
        var eligibilityGeneration = -1
        var allowed = false
        var queryEpoch = -1
        var maxima = SIMD8<Double>(repeating: -.infinity)
        init(path: String, modified: Date, version: String?) {
            self.path = path; self.modified = modified; self.version = version; modality = SemanticMediaPriority
                .of(path)
        }
    }

    private struct Row {
        var id: Int64
        var file: File
        var page: Int?
        var time: Double?
        var start: Int64?
        var end: Int64?
        var embedding: SemanticMediaInput.Kind?
        var bucket: SemanticScoreCalibration.Bucket
    }

    private struct Scored {
        var id: Int64
        var hit: AskFileHit
        var bucket: SemanticScoreCalibration.Bucket
    }

    private struct Page {
        var revision: Int64
        var rows: [Row]
        var values: [UInt16]
    }

    private struct Eligibility: Equatable {
        var scope: AskFileScope
        var type: AskFileType
        var fileExtension: String?
        var folder: [UInt8]?
    }

    private var eligibility: Eligibility?
    private var eligibilityGeneration = 0
    private var queryEpoch = 0
    private let lock = NSLock()
    private var database: OpaquePointer?
    private var pages: [Int64: Page] = [:]
    private var revisions: [Int64: Int64] = [:]
    private var cachedBytes = 0
    private let cacheLimit: Int
    private var pressureSource: DispatchSourceMemoryPressure?
    private var recoveringUntil: TimeInterval = 0
    private var nextPressureRead: TimeInterval = 0
    private var cacheAllowed = true
    var residentBytes: Int {
        lock.withLock { cachedBytes }
    }

    private(set) var loadedPages = 0

    init(url: URL, cacheLimit: Int = 256 * 1024 * 1024) throws {
        self.cacheLimit = max(0, cacheLimit)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else {
            sqlite3_close(database); database = nil; throw SemanticFileStore.Failure.database
        }
        sqlite3_busy_timeout(database, 50)
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.releaseMemory() }
        pressureSource = source; source.resume()
    }

    deinit { pressureSource?.cancel(); sqlite3_close(database) }
    func close() {
        lock.withLock { pages.removeAll(); cachedBytes = 0; sqlite3_close(database); database = nil }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var row: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, sql, -1, &row, nil) == SQLITE_OK, let row else {
            throw SemanticFileStore.Failure.database
        }
        return row
    }

    private func sql(_ sql: String) throws {
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SemanticFileStore.Failure.database
        }
    }

    private func string(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    func releaseMemory() {
        lock.withLock {
            pages.removeAll(); cachedBytes = 0
            recoveringUntil = ProcessInfo.processInfo.systemUptime + 5
            cacheAllowed = false; nextPressureRead = 0
        }
    }

    private func canCache() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextPressureRead {
            nextPressureRead = now + 1
            if let pressure = SemanticWorkBudget.currentPressure(), pressure > 0 {
                pages.removeAll(); cachedBytes = 0; recoveringUntil = now + 5
            }
            cacheAllowed = now >= recoveringUntil
        }
        return cacheAllowed
    }

    private func pageSize(_ page: Page) -> Int {
        // Include retained array capacity and conservatively charge a complete file object plus
        // string-storage headers per row, even when multiple rows actually share that object.
        page.values.capacity * MemoryLayout<UInt16>.stride
            + page.rows.capacity * MemoryLayout<Row>.stride
            + page.rows.reduce(0) { $0 + 256 + $1.file.path.utf8.count + ($1.file.version?.utf8.count ?? 0) }
    }

    private func page(_ number: Int64, cancelled: () -> Bool) throws -> Page {
        guard let revision = revisions[number] else { throw SemanticFileStore.Failure.database }
        if let cached = pages[number], cached.revision == revision {
            return cached
        }
        var files: [String: File] = [:]
        let value = try load(number, revision: revision, files: &files, cancelled: cancelled)
        let size = pageSize(value)
        if canCache(), size <= cacheLimit {
            while cachedBytes + size > cacheLimit, let victim = pages.keys.min(),
                  let old = pages.removeValue(forKey: victim) {
                cachedBytes -= pageSize(old)
            }
            pages[number] = value; cachedBytes += size
        }
        return value
    }

    private func refresh(cancelled: () -> Bool) throws {
        guard let database else { throw SemanticFileStore.Failure.database }
        try SemanticSQLiteCancellation.read(database, cancelled: cancelled) {
            let state = try statement("SELECT page_done FROM search_migration WHERE id=1")
            let complete = sqlite3_step(state) == SQLITE_ROW && sqlite3_column_int(state, 0) != 0
            sqlite3_finalize(state)
            // Only an interrupted legacy backfill needs this fallback; ordinary opens enumerate
            // the small page table, never the chunks. Its VM work is cancellable before row one.
            let rows = try statement(complete ? "SELECT page,revision FROM vector_pages" : """
            SELECT c.id/256,COALESCE(v.revision,0) FROM chunks c
                LEFT JOIN vector_pages v ON v.page=c.id/256 GROUP BY c.id/256
            """)
            defer { sqlite3_finalize(rows) }
            var next: [Int64: Int64] = [:], step = sqlite3_step(rows)
            while step == SQLITE_ROW {
                guard !cancelled() else { throw CancellationError() }
                next[sqlite3_column_int64(rows, 0)] = sqlite3_column_int64(rows, 1)
                step = sqlite3_step(rows)
            }
            guard step == SQLITE_DONE else { throw SemanticFileStore.Failure.database }
            for number in Array(pages.keys) where next[number] != pages[number]?.revision {
                if let old = pages.removeValue(forKey: number) {
                    cachedBytes -= pageSize(old)
                }
            }
            revisions = next
        }
    }

    private func resettingProfile() throws -> Bool {
        let row = try statement("SELECT 1 FROM profile_reset LIMIT 1")
        defer { sqlite3_finalize(row) }
        return sqlite3_step(row) == SQLITE_ROW
    }

    // swiftlint:disable:next function_body_length
    private func load(_ number: Int64, revision: Int64, files: inout [String: File],
                      cancelled: () -> Bool) throws -> Page {
        let row = try statement("""
        SELECT c.id,c.path,c.page,c.time,c.start_offset,c.end_offset,c.vector,f.modified,f.version,c.provenance,c.modality,c.search_script
        FROM chunks c JOIN files f ON f.path=c.path WHERE c.id>=? AND c.id<=? ORDER BY c.id
        """)
        defer { sqlite3_finalize(row) }
        let lower = number.multipliedReportingOverflow(by: 256)
        guard !lower.overflow, lower.partialValue >= 0 else { throw SemanticFileStore.Failure.database }
        sqlite3_bind_int64(row, 1, lower.partialValue); sqlite3_bind_int64(row, 2, lower.partialValue + 255)
        var rows: [Row] = [], floats: [Float] = []
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            guard !cancelled() else { throw CancellationError() }
            let path = string(row, 1)
            let media = SemanticMediaPriority.of(path) != .document
            if sqlite3_column_bytes(row, 6) == SemanticFilePolicy.dimension * 4,
               !media || string(row, 9) == SemanticFileStore.mediaProvenance,
               let raw = sqlite3_column_blob(row, 6) {
                let vector = UnsafeBufferPointer(
                    start: raw.assumingMemoryBound(to: Float.self),
                    count: SemanticFilePolicy.dimension
                )
                let norm = cblas_snrm2(Int32(vector.count), vector.baseAddress!, 1)
                if norm.isFinite, abs(norm - 1) < 0.02 {
                    let file: File
                    if let cached = files[path] {
                        file = cached
                    } else {
                        let version = string(row, 8)
                        file = File(path: path, modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 7)),
                                    version: version.isEmpty ? nil : version)
                        files[path] = file
                    }
                    let time = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil : sqlite3_column_double(row, 3)
                    rows.append(Row(id: sqlite3_column_int64(row, 0), file: file,
                                    page: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(
                                        row,
                                        2
                                    )),
                                    time: time.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? $0 : nil },
                                    start: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(
                                        row,
                                        4
                                    ),
                                    end: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(
                                        row,
                                        5
                                    ), embedding: string(row, 10) == "audio" ? .audio : (media ? .image : nil),
                                    bucket: .init(
                                        modality: file.modality,
                                        embedding: string(row, 10) == "audio" ? .audio : nil,
                                        script: Int(sqlite3_column_int(row, 11))
                                    )))
                    floats.append(contentsOf: vector)
                }
            }
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw SemanticFileStore.Failure.database }
        let elementCount = floats.count
        var compact = [UInt16](repeating: 0, count: elementCount)
        if !floats.isEmpty {
            try floats.withUnsafeMutableBytes { source in
                try compact.withUnsafeMutableBytes { target in
                    var input = vImage_Buffer(
                        data: source.baseAddress!,
                        height: 1,
                        width: UInt(elementCount),
                        rowBytes: source.count
                    )
                    var output = vImage_Buffer(
                        data: target.baseAddress!,
                        height: 1,
                        width: UInt(elementCount),
                        rowBytes: target.count
                    )
                    guard vImageConvert_PlanarFtoPlanar16F(&input, &output, 0) == kvImageNoError else {
                        throw SemanticFileStore.Failure.invalidVector
                    }
                }
            }
        }
        loadedPages += 1
        return Page(revision: revision, rows: rows, values: compact)
    }

    func prepare(cancelled: () -> Bool) throws {
        try lock.withLock {
            try sql("BEGIN")
            defer { try? sql("ROLLBACK") }
            if try resettingProfile() {
                return
            }
            try refresh(cancelled: cancelled)
            guard canCache() else { return }
            for number in revisions.keys.sorted() {
                try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
                if cachedBytes >= max(0, cacheLimit - 256 * (SemanticFilePolicy.dimension * 2 + 256)) {
                    break
                }
                _ = try page(number, cancelled: cancelled)
            }
        }
    }

    /// Blocks bound Float32 scratch to 768 KiB, regardless of corpus size. The resident matrix is Float16.
    static func scores(_ compact: [UInt16], vector: [Float], scratch: inout [Float]) throws -> [Float] {
        guard !compact.isEmpty else { return [] }
        guard vector.count == SemanticFilePolicy.dimension, compact.count % SemanticFilePolicy.dimension == 0 else {
            throw SemanticFileStore.Failure.invalidVector
        }
        let count = compact.count
        scratch = [Float](repeating: 0, count: count)
        try compact.withUnsafeBytes { source in
            try scratch.withUnsafeMutableBytes { target in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                          width: UInt(count), rowBytes: source.count)
                var output = vImage_Buffer(
                    data: target.baseAddress!,
                    height: 1,
                    width: UInt(count),
                    rowBytes: target.count
                )
                guard vImageConvert_Planar16FtoPlanarF(&input, &output, 0) == kvImageNoError else {
                    throw SemanticFileStore.Failure.invalidVector
                }
            }
        }
        let rows = count / SemanticFilePolicy.dimension
        var result = [Float](repeating: 0, count: rows)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(vector.count), 1, scratch,
                    Int32(vector.count), vector, 1, 0, &result, 1)
        return result
    }
}

extension SemanticVectorReader {
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    func search(vector: [Float], text: String, query: AskSearchQuery, type: AskFileType,
                scope: AskFileScope, limit: Int, cancelled: () -> Bool) throws -> [AskFileHit] {
        guard limit > 0, SemanticFileStore.valid(vector) else { return [] }
        return try lock.withLock {
            guard !cancelled() else { throw CancellationError() }
            try sql("BEGIN")
            defer { try? sql("ROLLBACK") }
            if try resettingProfile() {
                return []
            }
            let start = ProcessInfo.processInfo.systemUptime
            try refresh(cancelled: cancelled)
            SemanticSearchTrace.current?.measure(
                "snapshot-refresh",
                milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000
            )
            let ranking = SemanticSearchRanking(text)
            let lexical = try SemanticLexicalReader.candidates(database: database!, ranking: ranking, query: query,
                                                               type: type, scope: scope, limit: 100,
                                                               cancelled: cancelled)
            let evidence = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0.evidence) })
            let maximum = min(100, limit)
            var branches: [SemanticScoreCalibration.Bucket: [String: Scored]] = [:]
            var floors = [Double](repeating: -.infinity, count: SemanticScoreCalibration.Bucket.allCases.count)
            func offer(_ candidate: Scored) {
                let bucket = candidate.bucket, path = candidate.hit.path
                if let old = branches[bucket]?[path], old.hit.score > candidate.hit.score
                    || (old.hit.score == candidate.hit.score && old.id <= candidate.id) {
                    return
                }
                branches[bucket, default: [:]][path] = candidate
                if branches[bucket]!.count > maximum {
                    let worst = branches[bucket]!.min {
                        $0.value.hit.score == $1.value.hit.score ? $0.key > $1.key : $0.value.hit.score < $1.value.hit
                            .score
                    }!
                    branches[bucket]!.removeValue(forKey: worst.key)
                    floors[bucket.rawValue] = branches[bucket]!.values.map(\.hit.score).min() ?? -.infinity
                }
            }
            for candidate in lexical {
                offer(Scored(id: candidate.id, hit: candidate.hit, bucket: candidate.bucket))
            }
            var calibration = SemanticScoreCalibration()
            queryEpoch &+= 1
            var peak: (String, Double)?, runnerUp: (String, Double)?
            let key = Eligibility(scope: scope, type: type, fileExtension: query.fileExtension, folder: query.folder)
            if eligibility != key {
                eligibility = key; eligibilityGeneration &+= 1
            }
            var scratch: [Float] = []
            // Retain one Float32 scalar per row (4 MiB per million rows), then rank using the
            // completed calibration. Pruning on uncalibrated scores could discard a later winner.
            var scoredPages: [(Int64, [Float])] = []
            for number in revisions.keys.sorted() {
                let page = try page(number, cancelled: cancelled)
                guard !cancelled() else { throw CancellationError() }
                let scores = try Self.scores(page.values, vector: vector, scratch: &scratch)
                scoredPages.append((number, scores))
                for (index, row) in page.rows.enumerated() {
                    let cosine = Double(scores[index])
                    guard cosine.isFinite else { continue }
                    // Cache pure scope/type string predicates on the live immutable file metadata.
                    // Current filesystem authorization and identity are always rechecked at publication.
                    if row.file.eligibilityGeneration != eligibilityGeneration {
                        row.file.allowed = SemanticSearchRanking.allowed(
                            row.file.path,
                            query: query,
                            type: type,
                            scope: scope
                        )
                        row.file.eligibilityGeneration = eligibilityGeneration
                    }
                    guard row.file.allowed else { continue }
                    if row.file.queryEpoch != queryEpoch {
                        row.file.queryEpoch = queryEpoch; row.file.maxima = SIMD8(repeating: -.infinity)
                    }
                    if cosine > row.file.maxima[row.bucket.rawValue] {
                        row.file.maxima[row.bucket.rawValue] = cosine
                        calibration.observe(path: row.file.path, bucket: row.bucket, cosine: cosine)
                    }
                    // Distinct-file maxima prevent a long book's repeated chunks from defining confidence.
                    if peak?.0 == row.file.path {
                        peak = (row.file.path, max(peak!.1, cosine))
                    } else if runnerUp?.0 == row.file.path {
                        runnerUp = (row.file.path, max(runnerUp!.1, cosine))
                    } else if cosine > (runnerUp?.1 ?? -.infinity) {
                        runnerUp = (row.file.path, cosine)
                    }
                    if (runnerUp?.1 ?? -.infinity) > (peak?.1 ?? -.infinity) {
                        swap(&peak, &runnerUp)
                    }
                }
            }
            for (number, scores) in scoredPages {
                let page = try page(number, cancelled: cancelled)
                for row in page.rows where row.file.eligibilityGeneration != eligibilityGeneration {
                    row.file.allowed = SemanticSearchRanking.allowed(
                        row.file.path,
                        query: query,
                        type: type,
                        scope: scope
                    )
                    row.file.eligibilityGeneration = eligibilityGeneration
                }
                guard !cancelled() else { throw CancellationError() }
                for (index, row) in page.rows.enumerated() where row.file.allowed {
                    let cosine = Double(scores[index])
                    guard cosine.isFinite else { continue }
                    let lexical = evidence[row.id] ?? .init(coverage: 0, phrase: false, identifier: false)
                    guard var score = ranking.score(
                        cosine: cosine,
                        evidence: lexical,
                        modality: row.file.modality,
                        embedding: row.embedding
                    )
                    else { continue }
                    if !lexical.identifier, !(lexical.coverage == 1 && lexical.phrase) {
                        score += calibration.adjustment(row.bucket, cosine: cosine) + ranking
                            .scriptAdjustment(row.bucket)
                    }
                    guard score >= floors[row.bucket.rawValue] else { continue }
                    if let old = branches[row.bucket]?[row.file.path], old.hit.score > score
                        || (old.hit.score == score && old.id <= row.id) {
                        continue
                    }
                    let hit = AskFileHit(
                        path: row.file.path,
                        name: (row.file.path as NSString).lastPathComponent,
                        kind: .file,
                        modified: row.file.modified,
                        score: score,
                        evidence: .init(text: "", page: row.page, time: row.time,
                                        version: row.file
                                            .version,
                                        startOffset: row
                                            .start,
                                        endOffset: row.end)
                    )
                    offer(Scored(id: row.id, hit: hit, bucket: row.bucket))
                }
            }
            let confident = ranking.confident(peak: peak?.1 ?? 0, runnerUp: runnerUp?.1,
                                              completeLexical: lexical.contains { $0.evidence.coverage == 1 })
            var best: [String: Scored] = [:]
            for candidate in branches.values.flatMap(\.values) {
                guard confident || evidence[candidate.id].map(ranking.lexicalAccepted) == true else { continue }
                if let old = best[candidate.hit.path], old.hit.score > candidate.hit.score
                    || (old.hit.score == candidate.hit.score && old.id <= candidate.id) {
                    continue
                }
                best[candidate.hit.path] = candidate
            }
            let sorted = best.values.sorted {
                $0.hit.score == $1.hit.score ? $0.hit.path < $1.hit.path : $0.hit.score > $1.hit.score
            }
            var ordered = sorted
            if maximum >= 5, ranking.preferredModality == nil, ranking.identifiers.isEmpty, ranking.quoted.isEmpty {
                var counts: [SemanticScoreCalibration.Bucket: Int] = [:], head: [Scored] = []
                for candidate in sorted where head.count < 5 && (counts[candidate.bucket] ?? 0) < 2 {
                    head.append(candidate); counts[candidate.bucket, default: 0] += 1
                }
                let ids = Set(head.map(\.id))
                ordered = head + sorted.filter { !ids.contains($0.id) }
            }
            return try ordered.prefix(maximum).map { candidate in
                let id = candidate.id, value = candidate.hit
                let row = try statement("SELECT text FROM chunks WHERE id=?")
                defer { sqlite3_finalize(row) }
                sqlite3_bind_int64(row, 1, id)
                var hit = value
                if sqlite3_step(row) == SQLITE_ROW {
                    hit.evidence?.text = String(string(row, 0).prefix(180))
                }
                return hit
            }
        }
    }
}
