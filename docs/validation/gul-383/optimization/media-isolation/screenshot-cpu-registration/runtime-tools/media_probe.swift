import AppKit
import Foundation
@testable import Typeflux
@testable import TypefluxFocusedTests

/// Synthetic, opt-in diagnostics. Delegates every operation to the accepted production implementation.
final class MediaTrace: @unchecked Sendable {
    let lock = NSLock()
    let output: URL
    let start = ProcessInfo.processInfo.systemUptime
    init(_ output: URL) { self.output = output }
    func event(_ stage: String, _ fields: [String: Any] = [:]) {
        lock.withLock {
            var row = fields
            row["stage"] = stage
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
    }
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
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
            trace.event("media-response", ["dimensions": vector.count,
                "valid": SemanticFileStore.valid(vector), "squared_norm": vector.reduce(0) { $0 + $1 * $1 }])
            return vector
        } catch { trace.event("media-error", ["error": String(describing: error)]); throw error }
    }
    func release() { base.release(); trace.event("media-worker-released") }
}

@main @MainActor
struct MediaProbe {
    static func hit(_ hit: AskFileHit) -> [String: Any] {
        ["name": hit.name, "kind": hit.evidence?.segmentKind as Any? ?? NSNull(),
         "text": hit.evidence?.text as Any? ?? NSNull(), "time": hit.evidence?.time as Any? ?? NSNull(),
         "chunk_id": hit.evidence?.chunkID as Any? ?? NSNull(), "version": hit.evidence?.version != nil,
         "score": hit.score]
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
        let service = SemanticFileSearchService(settings: settings, directory: directory, helper: helper,
            supported: true, access: { true }, automaticStart: false, budgetEnabled: true,
            models: TracedModels(base: SemanticModelFiles(), trace: trace, label: "model"),
            mediaModels: TracedModels(base: SemanticMediaModelFiles(), trace: trace, label: "projector"),
            idle: { true }, makeMediaEncoder: { helper, model, projector in
                TracedMedia(helper: URL(fileURLWithPath: env["GUL405_MEDIA_HELPER"] ?? helper.path),
                    model: model, projector: projector, owners: owners, trace: trace)
            }, makeReader: { AskFileReader(executable: fileHelper, timeout: 30) }, embeddingOwners: owners)
        _ = NSApplication.shared
        var report: [String: Any] = ["complete": false, "budget_enabled": true,
            "media": env["GUL405_MEDIA"]!, "scope": "Single synthetic media; accepted Debug application and Release inference helper. Production resource/thermal/low-power checks enabled; idle callback controlled."]
        func save() {
            report["wall_seconds"] = ProcessInfo.processInfo.systemUptime - trace.start
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
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
        if service.chunks > 0 {
            let queries = env["GUL405_MEDIA"] == "screenshot" ? ["ERR-739204", "error dialog"] :
                (env["GUL405_MEDIA"] == "video" ? ["blue slide"] : ["a tone"])
            var rows: [[String: Any]] = []
            for text in queries {
                trace.event("query-begin", ["query": text])
                let hits = await service.search(text, type: .all, limit: 5)
                rows.append(["query": text, "hits": hits.map(hit)])
                trace.event("query-end", ["hits": hits.count])
            }
            report["queries"] = rows
            do {
                let reopened = try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"))
                let worker = SemanticEmbeddingWorker(helper: helper, model: service.modelURL)
                defer { worker.stop() }
                let text = queries[0]
                let vector = try await worker.query(text, lifecycle: AskSearchCancellation())
                let hits = try reopened.search(vector: vector, text: text, query: .init(text), type: .all,
                    scope: semanticScope(corpus.path), limit: 5, cancelled: { false })
                report["reopened_query"] = ["query": text, "hits": hits.map(hit)]
            } catch { report["reopen_error"] = String(describing: error) }
        }
        report["complete"] = report["ready"] as? Bool == true && !service.mediaFailed
        save()
        service.endSearch()
        await service.clear()
        defaults.removePersistentDomain(forName: suite)
        trace.event("service-cleared")
        report["cleaned_up"] = true; save()
        if report["complete"] as? Bool != true { exit(1) }
    }
}
