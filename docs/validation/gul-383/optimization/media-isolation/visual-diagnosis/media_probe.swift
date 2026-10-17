import AppKit
import Foundation
import SQLite3
@testable import Typeflux
@testable import TypefluxFocusedTests

/// Synthetic, opt-in diagnostics. Delegates every operation to the accepted production implementation.
final class MediaTrace: @unchecked Sendable {
    let lock = NSLock()
    let output: URL
    private let budgetLock = NSLock()
    private var budgets: [ObjectIdentifier: SemanticWorkBudget] = [:]
    let start = ProcessInfo.processInfo.systemUptime
    func captureBudget(_ stage: String) {
        guard let budget = SemanticWorkBudget.current else {
            event(stage, ["budget_present": false]); return
        }
        budgetLock.withLock { budgets[ObjectIdentifier(budget)] = budget }
        recordBudget(budget, stage: stage)
    }
    func recordBudget(_ budget: SemanticWorkBudget, stage: String) {
        let stats = budget.statistics
        event(stage, ["budget_present": true, "budget_id": String(describing: ObjectIdentifier(budget)),
            "enabled": budget.enabled, "yields": stats.yields, "yield_milliseconds": stats.milliseconds,
            "interruptions": stats.interruptions])
    }
    func sampleBudgets() {
        let values = budgetLock.withLock { Array(budgets.values) }
        for budget in values { recordBudget(budget, stage: "actual-budget-snapshot") }
    }
    init(_ output: URL) { self.output = output }
    func event(_ stage: String, _ fields: [String: Any] = [:]) {
        lock.withLock {
            var row = fields
            row["stage"] = stage
            row["uptime"] = ProcessInfo.processInfo.systemUptime
            row["pid"] = getpid()
            row["seconds"] = ProcessInfo.processInfo.systemUptime - start
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
        }
    }
}

struct TracedModels: SemanticModelHandling {
    let base: any SemanticModelHandling
    let trace: MediaTrace
    let label: String
    func verify(_ url: URL, cancelled: @Sendable () -> Bool) throws {
        trace.event(label + "-verify-begin")
        do {
            try base.verify(url, cancelled: cancelled)
            trace.event(label + "-verify-end")
        } catch { trace.event(label + "-verify-error", ["error": String(describing: error)]); throw error }
    }
    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try base.install(url, to: target, cancelled: cancelled)
    }
    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        trace.event(label + "-fetch-unexpected")
        throw URLError(.notConnectedToInternet)
    }
}

final class TracedMedia: SemanticMediaEmbedding {
    let base: SemanticEmbeddingWorker
    let trace: MediaTrace
    init(helper: URL, model: URL, projector: URL, owners: SemanticEmbeddingOwners, trace: MediaTrace) {
        self.trace = trace
        base = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true, projector: projector,
            timeout: 90, startupTimeout: 180, ownership: owners.media,
            authorization: owners.media.authorization())
        trace.event("media-worker-created")
        trace.captureBudget("media-worker-budget")
    }
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        trace.captureBudget("media-request-budget-before")
        defer { trace.captureBudget("media-request-budget-after") }
        trace.event("media-request", ["kind": input.kind.rawValue,
            "input": URL(fileURLWithPath: input.path).lastPathComponent,
            "time": input.time as Any? ?? NSNull(), "end_time": input.endTime as Any? ?? NSNull()])
        do {
            let events = SemanticSearchTrace(sink: { [trace] event in
                trace.event("helper-" + event.stage, ["milliseconds": event.milliseconds, "duration": event.duration])
            })
            let vector = try SemanticSearchTrace.$current.withValue(events) {
                try base.embed(input, cancelled: cancelled)
            }
            try JSONEncoder().encode(vector).write(to: trace.output.deletingLastPathComponent().appendingPathComponent("image-generated-vector.json"))
            trace.event("media-response", ["dimensions": vector.count,
                "valid": SemanticFileStore.valid(vector), "squared_norm": vector.reduce(0) { $0 + $1 * $1 }])
            return vector
        } catch { trace.event("media-error", ["error": String(describing: error)]); throw error }
    }
    func release() {
        trace.captureBudget("media-release-budget-before")
        base.release(); trace.event("media-worker-released")
        trace.captureBudget("media-release-budget-after")
    }
}

final class CapturedQuery: SemanticQueryEmbedding, @unchecked Sendable {
    let base: SemanticEmbeddingWorker
    private let lock = NSLock()
    private var vectors: [String: [Float]] = [:]
    init(helper: URL, model: URL, owner: SemanticEmbeddingOwnership) {
        base = SemanticEmbeddingWorker(helper: helper, model: model, ownership: owner)
    }
    func query(_ text: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        let vector = try await base.query(text, lifecycle: lifecycle)
        lock.withLock { vectors[text] = vector }; return vector
    }
    func captured(_ text: String) -> [Float]? { lock.withLock { vectors[text] } }
    func prepare(lifecycle: AskSearchCancellation) async throws { try await base.prepare(lifecycle: lifecycle) }
    func stop() { base.stop() }
}

@main @MainActor
struct MediaProbe {
    static func hit(_ hit: AskFileHit) -> [String: Any] {
        ["name": hit.name, "kind": hit.evidence?.segmentKind as Any? ?? NSNull(),
         "text": hit.evidence?.text as Any? ?? NSNull(), "time": hit.evidence?.time as Any? ?? NSNull(),
         "chunk_id": hit.evidence?.chunkID as Any? ?? NSNull(), "version": hit.evidence?.version != nil,
         "score": hit.score]
    }
    static func diagnose(_ store: SemanticFileStore, vector: [Float], text: String, corpus: String) throws -> [String: Any] {
        let ranking = SemanticSearchRanking(text)
        let lexical = try SemanticLexicalReader.candidates(database: store.database!, ranking: ranking,
            query: .init(text), type: .all, scope: semanticScope(corpus), limit: 100, cancelled: { false })
        let evidence = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0.evidence) })
        let row = try store.statement("SELECT id,path,vector,modality,segment_kind,provenance,text FROM chunks ORDER BY id")
        defer { sqlite3_finalize(row) }
        var rows: [[String: Any]] = [], maxima: [String: Double] = [:]
        while sqlite3_step(row) == SQLITE_ROW {
            let id = sqlite3_column_int64(row, 0), path = store.string(row, 1)
            let n = Int(sqlite3_column_bytes(row, 2))/4
            guard let raw = sqlite3_column_blob(row, 2), n == 768 else { continue }
            let values = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: n))
            var scratch: [Float] = []
            let score = Double(try SemanticVectorReader.scores(values.map { Float16($0).bitPattern }, vector: vector, scratch: &scratch)[0])
            let e = evidence[id] ?? .init(coverage: 0, phrase: false, identifier: false)
            let modality = SemanticMediaPriority.of(path), isOCR = store.string(row, 4) == "image-ocr"
            let accepted = ranking.score(cosine: score, evidence: e, modality: modality, embedding: isOCR ? nil : .image)
            let allowed = SemanticSearchRanking.allowed(path, query: .init(text), type: .all, scope: semanticScope(corpus))
            let expected = isOCR ? SemanticFileStore.imageRecipe : SemanticFileStore.mediaVectorProvenance(path, kind: .image)
            if allowed { maxima[path] = max(maxima[path] ?? -.infinity, score) }
            rows.append(["id": id, "name": URL(fileURLWithPath: path).lastPathComponent,
                "modality": store.string(row, 3), "segment_kind": store.string(row, 4), "provenance": store.string(row, 5),
                "provenance_matches": store.string(row, 5) == expected, "allowed": allowed,
                "vector_valid": SemanticFileStore.valid(values), "dimensions": n,
                "norm": sqrt(values.reduce(0.0) { $0 + Double($1)*Double($1) }),
                "float32_dot": zip(values, vector).reduce(0.0) { $0 + Double($1.0)*Double($1.1) },
                "scanner_cosine": score, "lexical_coverage": e.coverage,
                "candidate_score": accepted as Any? ?? NSNull()])
        }
        let ordered = maxima.values.sorted(by: >), peak = ordered.first ?? 0
        let runner = ordered.count > 1 ? ordered[1] : nil
        return ["query": text, "query_valid": SemanticFileStore.valid(vector),
            "query_norm": sqrt(vector.reduce(0.0) { $0 + Double($1)*Double($1) }),
            "semantic_floor": ranking.semanticFloor, "absolute_confidence_floor": 0.70,
            "distinct_files": maxima.count, "peak": peak, "runner_up": runner as Any? ?? NSNull(),
            "confident": ranking.confident(peak: peak, runnerUp: runner, completeLexical: lexical.contains { $0.evidence.coverage == 1 }),
            "lexical_candidate_count": lexical.count, "rows": rows]
    }
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["GUL405_PRIVATE_ROOT"]!)
        let output = URL(fileURLWithPath: env["GUL405_REPORT"]!)
        let trace = MediaTrace(URL(fileURLWithPath: env["GUL405_TRACE"]!))
        let suite = "gul405-media-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let corpus = root.appendingPathComponent("corpus")
        let directory = root.appendingPathComponent("models")
        var names = AskLauncherSearchSettings()
        names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let helper = URL(fileURLWithPath: env["GUL405_MODEL_HELPER"]!)
        let fileHelper = URL(fileURLWithPath: env["GUL405_FILE_HELPER"]!)
        let owners = SemanticEmbeddingOwners()
        let queryWorker = CapturedQuery(helper: helper,
            model: directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"), owner: owners.query)
        let service = SemanticFileSearchService(settings: settings, directory: directory, helper: helper,
            supported: true, access: { true }, automaticStart: false, budgetEnabled: true,
            models: TracedModels(base: SemanticModelFiles(), trace: trace, label: "model"),
            mediaModels: TracedModels(base: SemanticMediaModelFiles(), trace: trace, label: "projector"),
            idle: { true }, makeMediaEncoder: { helper, model, projector in
                TracedMedia(helper: URL(fileURLWithPath: env["GUL405_MEDIA_HELPER"] ?? helper.path),
                    model: model, projector: projector, owners: owners, trace: trace)
            }, makeReader: { AskFileReader(executable: fileHelper, timeout: 30) },
            makeQuery: { _, _ in queryWorker }, embeddingOwners: owners)
        _ = NSApplication.shared
        var report: [String: Any] = ["complete": false, "budget_enabled": true,
            "media": env["GUL405_MEDIA"]!, "scope": "Single synthetic media; accepted Debug application and Release inference helper. Production resource/thermal/low-power checks enabled; idle callback controlled."]
        func save() {
            report["wall_seconds"] = ProcessInfo.processInfo.systemUptime - trace.start
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        }
        if env["GUL405_MODE"] == "startup" {
            // One bounded native CPU startup/request regression; no document indexing or media decoding.
            let cutoff = trace.start + Double(env["GUL405_STAGE_SECONDS"]!)!
            let result: Result<[[Float]], Error> = await Task.detached(priority: .utility) {
                Result {
                    let budget = SemanticWorkBudget(enabled: true)
                    return try budget.perform(cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff }) {
                        trace.event("startup-model-verify-begin")
                        let model = directory.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
                        try SemanticModel.verify(model, cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff })
                        trace.event("startup-model-verify-end")
                        let worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true)
                        defer { worker.release() }
                        trace.event("startup-text-request")
                        let vectors = try worker.embed(["task: search result | query: warmup"],
                            cancelled: { ProcessInfo.processInfo.systemUptime >= cutoff })
                        trace.event("startup-text-response", ["dimensions": vectors.first?.count ?? 0])
                        return vectors
                    }
                }
            }.value
            switch result {
            case let .success(vectors):
                report["startup_vector_dimensions"] = vectors.map(\.count)
                report["startup_vectors_valid"] = vectors.allSatisfy(SemanticFileStore.valid)
                report["complete"] = vectors.count == 1 && vectors.allSatisfy(SemanticFileStore.valid)
            case let .failure(error): report["error"] = String(describing: error)
            }
            defaults.removePersistentDomain(forName: suite)
            report["mode"] = "startup"; report["cleaned_up"] = true; save()
            if report["complete"] as? Bool != true { exit(1) }
            return
        }
        let monitor = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                trace.sampleBudgets()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        trace.event("service-enable")
        let enabled = service.setEnabled(true)
        report["enabled"] = enabled
        let deadline = trace.start + Double(env["GUL405_STAGE_SECONDS"]!)!
        var snapshots: [[String: Any]] = []
        while enabled && ProcessInfo.processInfo.systemUptime < deadline {
            let pending = await service.processingPage(.pending, offset: 0)
            let completed = await service.processingPage(.completed, offset: 0)
            let items = (pending?.items ?? []) + (completed?.items ?? [])
            let snapshot: [String: Any] = ["seconds": ProcessInfo.processInfo.systemUptime - trace.start,
                "phase": String(describing: service.phase), "files": service.files, "chunks": service.chunks,
                "pressure": SemanticWorkBudget.currentPressure() as Any? ?? NSNull(),
                "waiting": service.resourceWaitReason.map { String(describing: $0) } as Any? ?? NSNull(),
                "media_failed": service.mediaFailed, "model_ready": service.modelReady,
                "current": service.currentProcessingPath.map { URL(fileURLWithPath: $0).lastPathComponent } as Any? ?? NSNull(),
                "items": items.map { item -> [String: Any] in
                    ["name": URL(fileURLWithPath: item.path).lastPathComponent, "state": item.displayState,
                     "reason": item.reason as Any? ?? NSNull(), "text_chunks": item.savedChunks,
                     "encoded_text": item.encodedChunks, "media_segments": item.savedMediaSegments,
                     "audio_covered": item.audioCovered as Any? ?? NSNull(),
                     "video_checked": item.videoChecked as Any? ?? NSNull()]
                }]
            snapshots.append(snapshot); report["snapshots"] = snapshots; save()
            if service.phase == .ready { break }
            try? await Task.sleep(for: .seconds(1))
        }
        report["ready"] = service.phase == .ready
        report["phase_before_pause"] = String(describing: service.phase)
        trace.event("index-observation-ended")
        service.pause(true)
        // A bounded index observation is also useful when legitimate pressure prevents readiness.
        if report["ready"] as? Bool == true && service.chunks > 0 && ProcessInfo.processInfo.systemUptime < deadline {
            let queries = env["GUL405_MEDIA"] == "screenshot" ? ["black text on a white background"] :
                (env["GUL405_MEDIA"] == "video" ? ["blue slide"] : ["a tone"])
            var rows: [[String: Any]] = []
            for text in queries {
                trace.event("query-begin", ["query": text])
                let request = Task { await service.search(text, type: .all, limit: 5) }
                let cutoff = Task {
                    do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) }
                    catch { return }
                    request.cancel()
                }
                let hits = await request.value
                cutoff.cancel(); await cutoff.value
                report["service_query_complete"] = hits.contains { $0.evidence?.segmentKind == "image" }
                rows.append(["query": text, "hits": hits.map(hit)])
                trace.event("query-end", ["hits": hits.count])
            }
            report["queries"] = rows
            do {
                let reopened = try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"))
                let text = queries[0]
                guard let vector = queryWorker.captured(text) else { throw SemanticFileStore.Failure.invalidVector }
                try JSONEncoder().encode(vector).write(to: output.deletingLastPathComponent().appendingPathComponent("query-vector.json"))
                let retained = output.deletingLastPathComponent().appendingPathComponent("synthetic.sqlite")
                var target: OpaquePointer?
                guard sqlite3_open(retained.path, &target) == SQLITE_OK, let target else { throw SemanticFileStore.Failure.database }
                defer { sqlite3_close(target) }
                guard let backup = sqlite3_backup_init(target, "main", reopened.database, "main") else { throw SemanticFileStore.Failure.database }
                let step = sqlite3_backup_step(backup, -1)
                let finish = sqlite3_backup_finish(backup)
                guard step == SQLITE_DONE, finish == SQLITE_OK else { throw SemanticFileStore.Failure.database }
                report["diagnosis"] = try diagnose(reopened, vector: vector, text: text, corpus: corpus.path)
                let hits = try reopened.search(vector: vector, text: text, query: .init(text), type: .all,
                    scope: semanticScope(corpus.path), limit: 5,
                    cancelled: { ProcessInfo.processInfo.systemUptime >= deadline })
                report["reopened_query"] = ["query": text, "hits": hits.map(hit)]
                let lexical = try reopened.lexicalSearch(text: "ERR-739204", query: .init("ERR-739204"), type: .all,
                    scope: semanticScope(corpus.path), limit: 5,
                    cancelled: { ProcessInfo.processInfo.systemUptime >= deadline })
                report["reopened_ocr_query"] = ["query": "ERR-739204", "hits": lexical.map(hit)]
                report["screenshot_retrieval_complete"] = hits.contains { $0.evidence?.segmentKind == "image" }
                    && lexical.contains { $0.evidence?.segmentKind == "image-ocr" }
            } catch { report["reopen_error"] = String(describing: error) }
        }
        report["complete"] = report["ready"] as? Bool == true && !service.mediaFailed
            && report["screenshot_retrieval_complete"] as? Bool == true
            && report["service_query_complete"] as? Bool == true
        save()
        service.endSearch()
        await service.clear()
        monitor.cancel(); await monitor.value
        await owners.media.native.waitUntilRetired()
        trace.sampleBudgets()
        trace.event("media-ownership-retired", ["occupied": owners.media.native.isOccupied])
        defaults.removePersistentDomain(forName: suite)
        trace.event("service-cleared")
        report["cleaned_up"] = true; save()
        if report["complete"] as? Bool != true { exit(1) }
    }
}
