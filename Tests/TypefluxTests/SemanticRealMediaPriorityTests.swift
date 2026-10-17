import AVFoundation
import Foundation
import Testing
@testable import Typeflux

private final class SemanticRecordingWatcher: AskFileWatching, @unchecked Sendable {
    private let watcher = AskFSEventsWatcher(), lock = NSLock()
    private var seen = Set<String>()
    func contains(_ path: String) -> Bool { lock.withLock { seen.contains(path) } }
    func start(paths: [String], since: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        watcher.start(paths: paths, since: since) { [self] changes, id in
            onChange(changes, id)
            lock.withLock { seen.formUnion(changes.map(\.path)) }
        }
    }
    func stop() { watcher.stop() }
}

private final class SemanticMediaPriorityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Double] = []
    private var records: [[String: Double]] = []
    private var idle = true
    let resumeFirst = DispatchSemaphore(value: 0)
    var completed: Int { lock.withLock { times.count } }
    var timestamps: [Double] { lock.withLock { times } }
    var events: [[String: Double]] { lock.withLock { records } }
    var isIdle: Bool { lock.withLock { idle } }
    func setIdle(_ value: Bool) { lock.withLock { idle = value } }
    func finish(_ time: Double, start: Double) -> Bool {
        lock.withLock {
            times.append(time)
            records.append(["segment_time": time, "start_uptime": start,
                            "end_uptime": ProcessInfo.processInfo.systemUptime])
            return times.count == 1
        }
    }
}

private final class SemanticObservedMedia: SemanticMediaEmbedding {
    let worker: SemanticEmbeddingWorker, probe: SemanticMediaPriorityProbe
    init(helper: URL, model: URL, projector: URL, probe: SemanticMediaPriorityProbe) {
        worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true, projector: projector,
                                         timeout: 90, startupTimeout: 180)
        self.probe = probe
    }
    func embed(_ input: SemanticMediaInput, cancelled: () -> Bool) throws -> [Float] {
        let start = ProcessInfo.processInfo.systemUptime
        let vector = try worker.embed(input, cancelled: cancelled)
        if probe.finish(input.time ?? -1, start: start) {
            // Hold only the first completed callback so a real FSEvent/voice transition is reproducible.
            while probe.resumeFirst.wait(timeout: .now() + 0.05) == .timedOut {
                if cancelled() { throw CancellationError() }
            }
        }
        return vector
    }
}

@Suite("Real media checkpoints and transcription priority", .serialized, .exclusiveUIState)
@MainActor
struct SemanticRealMediaPriorityTests {
    @Test func realAudioSegmentsYieldToNewDocumentsAndTranscriptionWhenRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["TYPEFLUX_SEMANTIC_CONTENTION_MODEL"],
              let projector = env["TYPEFLUX_SEMANTIC_CONTENTION_PROJECTOR"],
              let media = env["TYPEFLUX_SEMANTIC_CONTENTION_AUDIO"],
              let speech = env["TYPEFLUX_SEMANTIC_CONTENTION_SPEECH"],
              let asrFolder = env["TYPEFLUX_SEMANTIC_CONTENTION_ASR"] else { return }
        let root = try semanticFixture(), corpus = root.appendingPathComponent("corpus"), state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [corpus, state] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.linkItem(at: URL(fileURLWithPath: model), to: state.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        try FileManager.default.linkItem(at: URL(fileURLWithPath: projector), to: state.appendingPathComponent(SemanticMediaModel.name))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: media), to: corpus.appendingPathComponent("briefing.wav"))
        let handbook = corpus.appendingPathComponent("handbook.txt"), added = corpus.appendingPathComponent("new-document.txt")
        try "Expense reimbursement requires receipts.".write(to: handbook, atomically: true, encoding: .utf8)
        let suite = "semantic-real-media-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)), settings = SettingsStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        var names = AskLauncherSearchSettings(); names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let watcher = SemanticRecordingWatcher(), probe = SemanticMediaPriorityProbe()
        let service = SemanticFileSearchService(settings: settings, directory: state, supported: true,
            watcher: watcher, access: { true }, automaticStart: false, lowPowerMode: { false },
            thermalConstrained: { false }, idle: { probe.isIdle }, makeMediaEncoder: {
                SemanticObservedMedia(helper: $0, model: $1, projector: $2, probe: probe)
            })
        let store = try SemanticFileStore(url: state.appendingPathComponent("semantic-files.sqlite"))
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(240)
            while !ready(), service.phase != .failed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(ready(), "phase: \(service.phase), media failure: \(service.mediaFailed)")
        }
        do {
            try #require(service.setEnabled(true))
            try await wait { probe.completed == 1 }
            service.setForegroundBusy(true); probe.setIdle(false)
            let changedAt = ProcessInfo.processInfo.systemUptime
            try "Document priority checkpoint deltaunique.".write(to: added, atomically: true, encoding: .utf8)
            try await wait { watcher.contains(added.path) }
            // Let the service consume its main-actor FSEvents delivery before releasing the callback.
            try await Task.sleep(for: .milliseconds(100))
            probe.resumeFirst.signal()
            let asrStart = ProcessInfo.processInfo.systemUptime
            let speechURL = URL(fileURLWithPath: speech)
            let speechFile = try AVAudioFile(forReading: speechURL)
            let speechDuration = Double(speechFile.length) / speechFile.processingFormat.sampleRate
            let transcription = Task {
                try await SenseVoiceTranscriber(modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
                    modelFolder: asrFolder).transcribe(audioFile: AudioFile(fileURL: speechURL, duration: speechDuration))
            }
            let ftsStart = ProcessInfo.processInfo.systemUptime
            let hits = await service.search("reimbursement", type: .all, limit: 5)
            let ftsMs = (ProcessInfo.processInfo.systemUptime - ftsStart) * 1000
            #expect(hits.contains { $0.path == handbook.path })
            let transcript = try await transcription.value
            let asrEnd = ProcessInfo.processInfo.systemUptime
            #expect(!transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(probe.timestamps == [0], "no new media segment may start during foreground transcription")
            #expect(try store.counts().files == 1, "pending documents also yield to foreground voice work")
            service.setForegroundBusy(false)
            try await wait { service.indexProgress?.priorityUpdates == 1 }
            let published = await service.search("deltaunique", type: .all, limit: 5)
            let publishedAt = ProcessInfo.processInfo.systemUptime
            #expect(published.contains { $0.path == added.path })
            #expect(probe.timestamps == [0], "new documents publish while media still waits for idle")
            probe.setIdle(true)
            try await wait { service.phase == .ready }
            #expect(probe.timestamps == [0, 25, 50], "completed segments must not be repeated after a priority pause")
            let counts = try store.counts()
            #expect(counts.documents == 2 && counts.audio == 1 && counts.chunks == 5)
            let report: [String: Any] = ["model_sha256": SemanticModel.sha256, "projector_sha256": SemanticMediaModel.sha256,
                "build": _isDebugAssertConfiguration() ? "Debug" : "Release", "segments": probe.events,
                "document_change_uptime": changedAt, "document_publish_uptime": publishedAt,
                "change_to_publish_ms": (publishedAt - changedAt) * 1000,
                "voice_resume_to_publish_ms": (publishedAt - asrEnd) * 1000,
                "transcription_start_uptime": asrStart, "transcription_end_uptime": asrEnd,
                "transcription_audio_seconds": speechDuration,
                "transcript_nonempty": true, "fts_during_transcription_ms": ftsMs,
                "segment_times": probe.timestamps, "new_document_before_media_resume": true,
                "scope": "Real 65-second synthetic speech WAV, production extraction/helper/SQLite/FSEvents, pinned media projector, real SenseVoice CPU transcription. Foreground busy signal is driven at the service boundary; workflow callback wiring has a separate regression. First completed callback has an explicit test barrier; it is not a media latency benchmark."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to:
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("docs/validation/gul-383/optimization/real-media-priority.json"))
            await service.clear(removeModel: true)
        } catch {
            probe.resumeFirst.signal()
            await service.clear(removeModel: true); throw error
        }
    }
}
