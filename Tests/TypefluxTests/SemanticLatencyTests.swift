import Combine
import Darwin
import Foundation
import SQLite3
import Testing
@testable import Typeflux

private final class SemanticTimingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SemanticSearchTrace.Event] = []
    var events: [SemanticSearchTrace.Event] {
        lock.withLock { stored }
    }

    func record(_ event: SemanticSearchTrace.Event) {
        lock.withLock { stored.append(event) }
    }
}

private final class SemanticBenchmarkNames: AskFileSearching, @unchecked Sendable {
    let status = AskFileIndexStatus(phase: .ready)
    let usage: [String: Int] = [:]
    func search(_: AskSearchQuery, options _: AskFileSearchOptions) -> [AskFileHit] {
        []
    }

    func recent(options _: AskFileSearchOptions) -> [AskFileHit] {
        []
    }

    func start() {}
    func recordOpen(_: String) {}
    func forget(_: String) {}
    func rebuild() {}
    func clear() {}
}

private final class SemanticBenchmarkWatcher: AskFileWatching {
    func start(paths _: [String], since _: UInt64?, onChange _: @escaping ([AskFileChange], UInt64) -> Void) {}
    func stop() {}
}

/// Replay the baseline's scheduling, combined Store search and per-query metadata worker.
/// Caller publication is real; this is explicitly a baseline algorithm replay, not a historical app binary.
@MainActor
private final class SemanticLegacyProbe: SemanticFileSearching {
    let store: SemanticFileStore
    let scope: AskFileScope
    let model: URL
    private var lifecycle = AskSearchCancellation()
    private var worker: SemanticEmbeddingWorker
    init(store: SemanticFileStore, scope: AskFileScope, model: URL) {
        self.store = store; self.scope = scope; self.model = model
        worker = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: model)
    }

    func restart() {
        lifecycle.cancel(); lifecycle = AskSearchCancellation(); worker.stop()
        worker = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: model)
    }

    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] {
        let lifecycle = lifecycle, store = store, scope = scope
        do {
            try await Task.sleep(for: .milliseconds(160))
            let vector = try await worker.query(text, lifecycle: lifecycle)
            return try await Task.detached(priority: .userInitiated) {
                let hits = try store.search(vector: vector, text: text, query: .init(text), type: type,
                                            scope: scope, limit: limit * 2, cancelled: { lifecycle.isCancelled })
                let reader = AskFileReader()
                return Array(hits.filter { hit in
                    let response = try? reader.read(.init(
                        operation: .content,
                        path: hit.path,
                        scope: scope,
                        readText: false
                    ))
                    return response?.error == nil && response?.modified == hit.modified
                }.prefix(limit))
            }.value
        } catch { return [] }
    }

    deinit { lifecycle.cancel(); worker.stop() }
}

/// Opt-in provider publication benchmark. It does not equate publication with a displayed GPU frame.
@Suite("Semantic publication latency", .serialized, .exclusiveUIState)
@MainActor
struct SemanticLatencyTests {
    @Test func `measure both production entrypoints when explicitly requested`() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_BENCH_MODEL"] else { return }
        var mainActorGap = 0.0
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-latency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(temporary.path))
        let suite = "semantic-latency-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        var configuration = AskLauncherSearchSettings()
        configuration.fileRoots = [root.path]; configuration.excludedPaths = []
        settings.askLauncherSearchSettings = configuration
        let scope = SemanticFilePolicy.scope(names: configuration, fullDiskAccess: true)
        let noiseVector: [Float] = {
            var vector = [Float](repeating: 0, count: SemanticFilePolicy.dimension); vector[1] = 1
            return vector
        }()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let model = URL(fileURLWithPath: modelPath)
        try SemanticModel.verify(model)
        try FileManager.default.linkItem(at: model, to: root.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        let document = root.appendingPathComponent("handbook.txt"), noise = root.appendingPathComponent("noise.txt")
        try "Employees submit project expense reimbursement requests using the finance form. Attach receipts and obtain manager approval."
            .write(
                to: document,
                atomically: true,
                encoding: .utf8
            )
        try "synthetic filler".write(to: noise, atomically: true, encoding: .utf8)
        let encoder = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: model)
        defer { encoder.stop() }
        let vector = try encoder.embed(
            ["title: handbook.txt | text: " + String(contentsOf: document, encoding: .utf8)],
            cancelled: { false }
        )[0]
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let metadata = AskFileReader()
        for (url, embedding) in [(noise, noiseVector), (document, vector)] {
            let value = try metadata.read(.init(operation: .content, path: url.path, scope: scope, readText: false))
            try store.replace(path: url.path, modified: #require(value.modified), bytes: #require(value.fileSize),
                              chunks: [.init(text: url == document ? "reimbursement" : "synthetic filler", page: nil)],
                              vectors: [embedding])
            // This deliberately synthetic load is already complete. Without compatible jobs the
            // GUL-403 migration correctly re-extracts the two source files, destroying the scale fixture.
            try store.lock.withLock {
                try store.transaction {
                    try store.execute("UPDATE files SET version=? WHERE path=?", [value.version ?? "", url.path])
                    try store.execute("""
                    INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,extracted,recipe)
                    VALUES(?,?,?,'done','{"page":0,"offset":0}',1,?)
                    """, [
                        url.path,
                        SemanticFileStore.version(value),
                        "benchmark-load",
                        SemanticFileStore.documentProvenance
                    ])
                    try store.execute("UPDATE chunks SET generation=?,provenance=? WHERE path=?",
                                      ["benchmark-load", SemanticFileStore.documentProvenance, url.path])
                }
            }
        }
        var database: OpaquePointer?
        try #require(sqlite3_open(store.url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, """
        BEGIN IMMEDIATE;
        WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<\(max(1, Int(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")! - 2)))
        INSERT INTO chunks(path,text,page,vector) SELECT c.path,c.text,c.page,c.vector FROM chunks c CROSS JOIN numbers WHERE c.id=1;
        INSERT INTO lexical(rowid,terms) SELECT id,'synthetic filler' FROM chunks WHERE id>2;
        COMMIT;
        """, nil, nil, nil) == SQLITE_OK)
        #expect(try store.counts().chunks == 100_000)
        try prepareNativeSearchGeneration(database)
        let service = SemanticFileSearchService(settings: settings, directory: root, supported: true,
                                                watcher: SemanticBenchmarkWatcher(), access: { true },
                                                automaticStart: false,
                                                lowPowerMode: { false }, thermalConstrained: { false })
        service.pause(true)
        #expect(service.setEnabled(true))
        try await wait { service.phase == .paused && service.modelReady }
        let names = SemanticBenchmarkNames(), mixed = AskQuickSearchSession()
        let legacy = SemanticLegacyProbe(store: store, scope: scope, model: model)
        var fileMode: AskPluginSession!
        var rows: [[String: Any]] = []
        func wait(_ done: @MainActor () -> Bool) async throws {
            let until = ContinuousClock.now + .seconds(45)
            var previous = ContinuousClock.now
            while !done(), ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(1))
                let gap = previous.duration(to: .now).components
                mainActorGap = max(mainActorGap, Double(gap.seconds) * 1000 + Double(gap.attoseconds) / 1e15)
                previous = .now
            }
            try #require(done())
        }
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: .now).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        for implementation in ["legacy-replay", "current"] {
            let provider: any SemanticFileSearching = implementation == "current" ? service : legacy
            let plugin = AskFileSearchPlugin(index: { names }, settings: { .init() }, semantic: { provider })
            fileMode = AskPluginSession(plugins: [plugin], keywords: { AskFileSearchPlugin.keywords })
            for entry in ["mixed", "file-mode"] {
                legacy.restart()
                service.endSearch()
                service.start(force: true)
                try await wait { service.phase == .paused && service.modelReady }
                for scenario in ["cold", "cache-hit", "hot-new-query", "index-writer"] {
                    if scenario != "cold" {
                        provider.prepareForSearch()
                        try await wait { service.queryState != .warming }
                    }
                    let writerToken = AskSearchCancellation()
                    defer { writerToken.cancel() }
                    let writer: Task<Void, Error>? = scenario == "index-writer" ? Task.detached {
                        while !writerToken.isCancelled {
                            try store.replace(path: root.path + "/writer.txt", modified: Date(), bytes: 1,
                                              chunks: [.init(text: "background", page: nil)], vectors: [noiseVector])
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } : nil
                    for round in 0 ..< (scenario == "cold" ? 1 : 100) {
                        let text = scenario == "cache-hit" ? "reimbursement" :
                            "How can I get back money spent during business travel \(entry) \(scenario) \(round)"
                        if scenario == "hot-new-query" {
                            #expect(try store.lexicalSearch(text: text, query: .init(text), type: .all,
                                                            scope: scope, limit: 5, cancelled: { false })
                                    .isEmpty)
                        }
                        mixed.cancel(); mixed.results = nil
                        fileMode.enter(AskFileSearchPlugin.keywords[0])
                        mainActorGap = 0
                        let start = ContinuousClock.now
                        let recorder = SemanticTimingRecorder()
                        let trace = SemanticSearchTrace(sink: { recorder.record($0) })
                        var first: Double?
                        if entry == "mixed" {
                            let watch = mixed.$results.sink { value in
                                if first == nil, value?.files.contains(where: { $0.path == document.path }) == true {
                                    first = milliseconds(start)
                                }
                            }
                            SemanticSearchTrace.$current.withValue(trace) {
                                mixed.update(text: text, chinese: false, calculator: false,
                                             sources: .init(files: names, semantic: provider))
                            }
                            try await wait { !mixed.isSearching }
                            watch.cancel()
                        } else {
                            let watch = fileMode.$partial.sink { value in
                                if first == nil,
                                   value?.items.contains(where: { $0.fileHit?.path == document.path }) == true {
                                    first = milliseconds(start)
                                }
                            }
                            SemanticSearchTrace.$current.withValue(trace) {
                                fileMode.update(text: text, selection: nil, language: .english)
                            }
                            try await wait { fileMode.output != nil }
                            watch.cancel()
                        }
                        let events = recorder.events.map { [
                            "stage": $0.stage,
                            "milliseconds": $0.milliseconds,
                            "duration": $0.duration
                        ] as [String: Any] }
                        rows.append([
                            "implementation": implementation,
                            "events": events,
                            "entry": entry,
                            "scenario": scenario,
                            "round": round,
                            "first_hit_ms": first as Any? ?? NSNull(),
                            "complete_ms": milliseconds(start),
                            "main_actor_max_timer_gap_ms": mainActorGap
                        ])
                    }
                    writerToken.cancel()
                    try await writer?.value
                }
            }
        }
        mixed.cancel(); fileMode.deactivate()
        await service.clear(removeModel: true)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var children = rusage()
        getrusage(RUSAGE_CHILDREN, &children)
        let report: [String: Any] = [
            "thermal_before": thermalBefore,
            "thermal_after": ProcessInfo.processInfo.thermalState.rawValue,
            "system_low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "app_max_rss_bytes": usage.ru_maxrss,
            "max_reaped_child_rss_bytes": children.ru_maxrss,
            "main_actor_gap_scope": "Largest observed 1ms main-actor polling interval per query, not native frame latency",
            "scope": "Actual mixed session and f plugin session from accepted input to main-actor publication; native file permission worker, real Release model helper, 100k synthetic Float32 vectors. Not render latency.",
            "rows": rows,
            "model_sha256": SemanticModel.sha256,
            "comparison": "Baseline scheduling/Store/permission algorithm replay versus the current service, through both actual launcher publication sessions",
            "cold_definition": "Fresh query helper and permission reader; model file and OS/Metal shader caches may be warm",
            "index_writer_concurrency": 1,
            "index_inference_concurrency": 0,
            "build": _isDebugAssertConfiguration() ? "Debug with coverage" : "Release"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/validation/gul-383/optimization/publication-latency.json"))
    }
}

/// Shared synthetic load for native UI measurements. Only the winning passage uses a real document vector.
@MainActor
struct SemanticNativeBenchmarkData {
    let root: URL
    let document: URL
    let store: SemanticFileStore
    let scope: AskFileScope
    let service: SemanticFileSearchService
    let names: any AskFileSearching
    let backgroundVector: [Float]
    let noiseVectorSource: String
    let defaults: UserDefaults
    let suite: String
    let loadSeconds: Double
    var diskBytes: Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            total +
                ((try? FileManager.default.attributesOfItem(atPath: store.url.path + suffix)[.size] as? NSNumber)?
                    .int64Value ?? 0)
        }
    }

    // Keep untimed corpus preparation together so measured query boundaries stay visible.
    // swiftlint:disable:next function_body_length
    static func make(model: URL,
                     makeEncoder: @escaping @Sendable (URL, URL) -> any SemanticEmbedding = {
                         SemanticEmbeddingWorker(helper: $0, model: $1, indexing: true)
                     }) throws -> Self {
        let loading = ProcessInfo.processInfo.systemUptime
        try SemanticModel.verify(model)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("semantic-native-latency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: AskFileScope.canonical(temporary.path))
        try FileManager.default.linkItem(at: model, to: root.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        let suite = "semantic-native-latency-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)), settings = SettingsStore(defaults: defaults)
        var configuration = AskLauncherSearchSettings()
        configuration.fileRoots = [root.path]; configuration.excludedPaths = []
        settings.askLauncherSearchSettings = configuration
        let scope = SemanticFilePolicy.scope(names: configuration, fullDiskAccess: true)
        let document = root.appendingPathComponent("handbook.txt"), noise = root.appendingPathComponent("noise.txt")
        let text = "Employees submit project expense reimbursement requests using the finance form. Attach receipts and obtain manager approval."
        let realNoise = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_REAL_NOISE"] == "1"
        let noiseText = realNoise ? "Basalt crystals beneath volcanic ridges. Quartz mineral formations."
            : "synthetic filler"
        try text.write(to: document, atomically: true, encoding: .utf8)
        try noiseText.write(to: noise, atomically: true, encoding: .utf8)
        var background = [Float](repeating: 0, count: SemanticFilePolicy.dimension); background[1] = 1
        let encoder = SemanticEmbeddingWorker(helper: SemanticModel.helperURL, model: model)
        defer { encoder.release() }
        if realNoise {
            background = try encoder.embed(["title: noise.txt | text: " + noiseText], cancelled: { false })[0]
        }
        let vector = try encoder.embed(["title: handbook.txt | text: " + text], cancelled: { false })[0]
        let store = try SemanticFileStore(url: root.appendingPathComponent("semantic-files.sqlite"))
        let metadata = AskFileReader()
        for (url, embedding) in [(noise, background), (document, vector)] {
            let value = try metadata.read(.init(operation: .content, path: url.path, scope: scope, readText: false))
            try store.replace(path: url.path, modified: #require(value.modified), bytes: #require(value.fileSize),
                              chunks: [.init(text: url == document ? text : noiseText, page: nil)],
                              vectors: [embedding])
            // This deliberately synthetic load is already complete. Without compatible jobs the
            // GUL-403 migration correctly re-extracts the two source files, destroying the scale fixture.
            try store.lock.withLock {
                try store.transaction {
                    try store.execute("UPDATE files SET version=? WHERE path=?", [value.version ?? "", url.path])
                    try store.execute("""
                    INSERT OR REPLACE INTO jobs(path,version,generation,state,cursor,extracted,recipe)
                    VALUES(?,?,?,'done','{"page":0,"offset":0}',1,?)
                    """, [
                        url.path,
                        SemanticFileStore.version(value),
                        "benchmark-load",
                        SemanticFileStore.documentProvenance
                    ])
                    try store.execute("UPDATE chunks SET generation=?,provenance=? WHERE path=?",
                                      ["benchmark-load", SemanticFileStore.documentProvenance, url.path])
                }
            }
        }
        var database: OpaquePointer?
        try #require(sqlite3_open(store.url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, """
        BEGIN IMMEDIATE;
        WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<\(max(1, Int(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")! - 2)))
        INSERT INTO chunks(path,text,page,vector) SELECT c.path,c.text,c.page,c.vector FROM chunks c CROSS JOIN numbers WHERE c.id=1;
        INSERT INTO lexical(rowid,terms) SELECT id,'\(SemanticFilePolicy.terms(noiseText))' FROM chunks WHERE id>2;
        COMMIT;
        """, nil, nil, nil) == SQLITE_OK)
        try prepareNativeSearchGeneration(database)
        let service = SemanticFileSearchService(settings: settings, directory: root, supported: true,
                                                watcher: SemanticBenchmarkWatcher(), access: { true },
                                                automaticStart: false,
                                                lowPowerMode: { false }, thermalConstrained: { false },
                                                makeEncoder: makeEncoder)
        // Let budgeted startup finish before pausing; a real pause also holds schema preparation.
        try #require(service.setEnabled(true))
        return Self(root: root, document: document, store: store, scope: scope, service: service,
                    names: SemanticBenchmarkNames(), backgroundVector: background,
                    noiseVectorSource: realNoise ? "real-pinned-model-geology-document" : "constructed-orthogonal",
                    defaults: defaults, suite: suite,
                    loadSeconds: ProcessInfo.processInfo.systemUptime - loading)
    }

    func clear() async {
        service.endSearch()
        await service.clear(removeModel: true)
        // The fixture also owns a writer connection, independently of the service's Store.
        try? store.destroy()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Raw scale fixtures deliberately bypass the application writer; mirror the generated FTS table
/// outside every measured boundary. The baseline has no shadow table and remains unchanged.
func prepareNativeSearchGeneration(_ database: OpaquePointer?) throws {
    var row: OpaquePointer?
    try #require(sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE name='lexical_v4'", -1, &row, nil) ==
        SQLITE_OK)
    let exists = sqlite3_step(row) == SQLITE_ROW; sqlite3_finalize(row)
    if exists {
        try #require(sqlite3_exec(database, """
        BEGIN IMMEDIATE;
        DELETE FROM lexical_v4 WHERE rowid IN (SELECT id FROM search_dirty);
        INSERT INTO lexical_v4(rowid,terms) SELECT c.id,l.terms FROM search_dirty d JOIN chunks c ON c.id=d.id JOIN lexical l ON l.rowid=c.id;
        DELETE FROM search_dirty;
        COMMIT;
        """, nil, nil, nil) == SQLITE_OK)
    }
}
