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
            try JSONEncoder().encode(vector).write(to: trace.output.deletingLastPathComponent().appendingPathComponent("audio-vector-\(Int(input.time ?? -1)).json"))
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
struct AudioServiceProbe {
    static func main() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: environment["GUL405_PRIVATE_ROOT"]!)
        let out = URL(fileURLWithPath: environment["GUL405_REPORT"]!).deletingLastPathComponent()
        let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let evidence = repository.appendingPathComponent("docs/validation/gul-383/optimization/audio-live/live-visible-root")
        let corpus = root.appendingPathComponent("corpus"), models = root.appendingPathComponent("models")
        let helper = URL(fileURLWithPath: environment["GUL405_MODEL_HELPER"]!)
        let fileHelper = URL(fileURLWithPath: environment["GUL405_FILE_HELPER"]!)
        let reader = AskFileReader(executable: fileHelper, timeout: 3)
        defer { reader.stop() }
        let store = try SemanticFileStore(url: models.appendingPathComponent("semantic-files.sqlite"))
        let captured = try JSONDecoder().decode(SemanticCalibratedEvaluationTests.Captured.self, from: Data(contentsOf:
            repository.appendingPathComponent("docs/validation/gul-383/optimization/ranking-scale/raw-quality-vectors.json")))
        for (document, vector) in zip(captured.documents, captured.vectors) {
            let file = corpus.appendingPathComponent(document.id + ".txt")
            try document.text.write(to: file, atomically: true, encoding: .utf8)
            let metadata = try reader.read(.init(operation: .content, path: file.path,
                scope: semanticScope(corpus.path), readText: false), isCancelled: { false })
            guard metadata.error == nil, let modified = metadata.modified, let bytes = metadata.fileSize
            else { throw SemanticFileStore.Failure.database }
            try store.replace(path: file.path, modified: modified, bytes: bytes,
                chunks: [.init(text: document.text, page: nil)], vectors: [vector])
        }
        let audio = corpus.appendingPathComponent("boundary.wav")
        let metadata = try reader.read(.init(operation: .content, path: audio.path,
            scope: semanticScope(corpus.path), readText: false), isCancelled: { false })
        guard metadata.error == nil else { throw SemanticFileStore.Failure.database }
        let generation = try store.beginMediaJob(path: audio.path, metadata: metadata)
        for (ordinal, time) in [0, 25].enumerated() {
            let vector = try JSONDecoder().decode([Float].self, from: Data(contentsOf:
                evidence.appendingPathComponent("audio-vector-\(time).json")))
            try store.saveMediaSegment(path: audio.path, generation: generation, ordinal: ordinal,
                input: .init(kind: .audio, path: audio.path, time: Double(time), endTime: Double(time + 30)), vector: vector)
        }
        guard try store.commitMediaJob(path: audio.path, generation: generation, metadata: metadata, segments: 2)
        else { throw SemanticFileStore.Failure.database }
        let suite = "gul405-audio-query-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        var names = AskLauncherSearchSettings(); names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let owners = SemanticEmbeddingOwners()
        let trace = MediaTrace(URL(fileURLWithPath: environment["GUL405_TRACE"]!))
        let query = CapturedQuery(helper: helper, model: models.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"), owner: owners.query)
        let service = SemanticFileSearchService(settings: settings, directory: models, helper: helper,
            supported: true, access: { true }, automaticStart: false, budgetEnabled: true,
            idle: { true }, makeReader: { AskFileReader(executable: fileHelper, timeout: 3) },
            makeQuery: { _, _ in query }, embeddingOwners: owners)
        _ = NSApplication.shared
        let enabled = service.setEnabled(true)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !service.modelReady && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        service.pause(true)
        let preparedPhase = String(describing: service.phase)
        let hits = await service.search("a tone", type: .all, limit: 5)
        let vector = query.captured("a tone") ?? []
        try JSONEncoder().encode(vector).write(to: out.appendingPathComponent("fresh-query-vector.json"))
        let reopened = try SemanticFileStore(url: store.url)
        let found = try reopened.search(vector: vector, text: "a tone", query: .init("a tone"), type: .all,
            scope: semanticScope(corpus.path), limit: 5, cancelled: { false })
        func mapped(_ hits: [AskFileHit]) -> [[String: Any]] {
            hits.map { ["name": $0.name, "kind": $0.evidence?.segmentKind as Any? ?? NSNull(),
                "time": $0.evidence?.time as Any? ?? NSNull(), "version": $0.evidence?.version as Any? ?? NSNull(), "score": $0.score] }
        }
        let success = enabled && hits.first?.name == "boundary.wav" && hits.first?.evidence?.time == 25
            && hits.first?.evidence?.segmentKind == "audio-window" && found.first?.name == "boundary.wav"
        let report: [String: Any] = ["complete": success, "live_query": vector.count == 768, "prepared_phase": preparedPhase, "model_ready": service.modelReady, "actual_file_metadata": true,
            "reused_audio_vectors": 2, "reused_original_text_vectors": captured.documents.count,
            "budget_enabled": true, "query": "a tone", "service": mapped(hits), "reopened": mapped(found),
            "wall_seconds": ProcessInfo.processInfo.systemUptime - start,
            "scope": "New live query and actual isolated metadata validation; retained audio and original text vectors. No new audio inference or UI claim."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("report.json"))
        await service.clear()
        defaults.removePersistentDomain(forName: suite)
        if !success { exit(1) }
    }
}
