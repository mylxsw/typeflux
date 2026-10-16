import AppKit
import AVFoundation
import Combine
import Darwin
import SwiftUI
import Testing
@testable import Typeflux

/// Observes real production batches without changing their scheduling or vectors.
final class SemanticInferenceObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var started: [Double] = []
    private var finished: [Double] = []
    private var encodedTexts = 0
    var successfulTexts: Int {
        lock.withLock { encodedTexts }
    }

    var startedBatches: Int {
        lock.withLock { started.count }
    }

    var active: Bool {
        lock.withLock { started.count > finished.count }
    }

    var completed: Int {
        lock.withLock { finished.count }
    }

    var intervals: [[Double]] {
        lock.withLock { zip(started, finished).map { [$0, $1] } }
    }

    func begin() {
        lock.withLock { started.append(ProcessInfo.processInfo.systemUptime) }
    }

    func end(texts: Int) {
        lock.withLock { finished.append(ProcessInfo.processInfo.systemUptime); encodedTexts += texts }
    }
}

private final class SemanticObservedEncoder: SemanticEmbedding {
    let worker: SemanticEmbeddingWorker
    let observer: SemanticInferenceObserver
    init(helper: URL, model: URL, observer: SemanticInferenceObserver) {
        worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true)
        self.observer = observer
    }

    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        observer.begin()
        do {
            let vectors = try worker.embed(texts, cancelled: cancelled)
            observer.end(texts: texts.count); return vectors
        } catch {
            observer.end(texts: 0); throw error
        }
    }

    func release() {
        worker.release()
    }
}

@Suite("Native input during real document inference", .serialized, .exclusiveUIState)
@MainActor
// The foreground measurement and cleanup share one lifecycle and observation window.
// swiftlint:disable:next type_body_length
struct SemanticNativeContentionTests {
    private func editor(in root: NSView) -> AskComposerTextView.Editor? {
        if let value = root as? AskComposerTextView.Editor {
            return value
        }
        return root.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test func `measure both entries during real indexing when requested`() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_CONTENTION_MODEL"] else { return }
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        var rows: [[String: Any]] = [], entries: [[String: Any]] = []
        let largeScale = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] == "1000000"
        let warmSamples = largeScale ? 20 : 100
        var failedBodySamples = 0
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        var timerGap = 0.0
        var stage = "setup", finished = false
        func checkpoint() throws {
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "docs/validation/gul-383/optimization/ranking-scale/contention-\(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_LABEL"] ?? "after")-\(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000").partial.json"
                )
            try JSONSerialization.data(withJSONObject: ["rows": rows, "entries": entries, "stage": stage,
                                                        "complete": finished], options: [.prettyPrinted, .sortedKeys])
                .write(to: output)
        }
        defer { try? checkpoint() }
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(largeScale ? 120 : 45)
            var last = ContinuousClock.now
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
                timerGap = max(timerGap, ms(last)); last = .now
            }
            try #require(ready(), "Benchmark wait failed at \(stage)")
        }
        for fileMode in [false, true] {
            let observer = SemanticInferenceObserver()
            let data = try SemanticNativeBenchmarkData.make(model: URL(fileURLWithPath: model), makeEncoder: {
                SemanticObservedEncoder(helper: $0, model: $1, observer: observer)
            })
            do {
                stage = "initial-readiness-\(fileMode)"
                try await wait { data.service.phase == .ready && data.service.modelReady }
                data.service.pause(true)
                try #require(
                    try data.store.counts()
                        .chunks == Int(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000"),
                    "Startup must retain every seeded scale row"
                )
                // Keep real documents available beyond the measured window, without a synthetic write loop.
                let background = String(
                    repeating: "Basalt crystals beneath volcanic ridges. Quartz mineral formations. ",
                    count: 800
                )
                for index in 0 ..< 512 {
                    try background.write(to: data.root.appendingPathComponent("geology-\(index).txt"),
                                         atomically: true, encoding: .utf8)
                }
                data.service.pause(false)
                // Startup now reuses completed discovery. The inert fixture watcher requires
                // an explicit rescan for files created after startup, outside timed input samples.
                data.service.rescanAll()
                stage = "index-start-\(fileMode)"
                try await wait { data.service.phase == .indexing && observer.completed > 0 }
                data.service.prepareForSearch()
                stage = "prewarm-\(fileMode)"
                try await wait { data.service.queryState != .warming }
                let fixture = try AskTestFixture(authenticated: false)
                defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
                fixture.model.semanticSearch = data.service; fixture.model.fileIndex = data.names
                if fileMode {
                    fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AskComposer(model: fixture.model, launcher: true).padding(20))
                host.sizingOptions = []; window.contentView = host; window.orderFront(nil)
                defer { window.close() }
                try await wait { editor(in: host) != nil }
                let input = try #require(editor(in: host))
                func drawn() -> Bool {
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    return SettingsBehaviorTestSupport.elements(in: host).contains {
                        $0.text.contains("handbook.txt") || $0.label.contains("handbook.txt")
                    }
                }
                func settled(_ text: String) -> Bool {
                    fileMode ? fixture.model.plugins.isPlanCurrent && fixture.model.plugins.request?.text == text
                        && fixture.model.plugins.output != nil :
                        fixture.model.quickSearch.isCurrent(text: text) && !fixture.model.quickSearch.isSearching
                }
                for scenario in ["fts-real-index", "semantic-real-index"] {
                    for round in 0 ..< warmSamples {
                        stage = "clear-\(fileMode)-\(scenario)-\(round)"
                        if !input.string.isEmpty {
                            input.selectAll(nil); input.deleteBackward(nil)
                        }
                        try await wait {
                            fixture.model.launcherDraft.text.isEmpty && !drawn() && settled("")
                        }
                        stage = "active-inference-\(fileMode)-\(scenario)-\(round)"
                        try await wait { observer.active }
                        let text = scenario == "fts-real-index" ? "reimbursement" :
                            "How can I get back money spent during business travel contention \(fileMode) \(round)"
                        if scenario == "semantic-real-index" {
                            #expect(try data.store.lexicalSearch(text: text, query: .init(text), type: .all,
                                                                 scope: data.scope, limit: 5, cancelled: { false })
                                    .isEmpty)
                        }
                        // Lexical inspection precedes the timed active-batch boundary.
                        stage = "active-inference-\(fileMode)-\(scenario)-\(round)"
                        try await wait { observer.active }
                        timerGap = 0
                        let start = ContinuousClock.now, uptime = ProcessInfo.processInfo.systemUptime
                        let completedBeforeInput = observer.completed
                        var published: Double?
                        let watch: AnyCancellable = if fileMode {
                            fixture.model.plugins.$partial.sink { value in
                                if published == nil, fixture.model.plugins.request?.text == text,
                                   value?.items.contains(where: { $0.fileHit?.path == data.document.path }) == true {
                                    published = ms(start)
                                }
                            }
                        } else {
                            fixture.model.quickSearch.$results.sink { value in
                                if published == nil, fixture.model.quickSearch.isCurrent(text: text),
                                   value?.files.contains(where: { $0.path == data.document.path }) == true {
                                    published = ms(start)
                                }
                            }
                        }
                        input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                        stage = "publish-\(fileMode)-\(scenario)-\(round)"
                        try await wait { published != nil || settled(text) }
                        var drawing: Double?
                        if published != nil {
                            stage = "draw-\(fileMode)-\(scenario)-\(round)"
                            try await wait { drawn() }
                            drawing = ms(start)
                        } else {
                            failedBodySamples += 1
                        }
                        stage = "settled-\(fileMode)-\(scenario)-\(round)"
                        try await wait { settled(text) }
                        watch.cancel()
                        let complete = ms(start), gap = timerGap
                        stage = "batch-finish-\(fileMode)-\(scenario)-\(round)"
                        try await wait { observer.completed > completedBeforeInput }
                        let overlaps = observer.intervals.filter { $0[0] <= uptime && $0[1] >= uptime }
                        #expect(overlaps.count == 1, "the input must overlap a real background inference")
                        rows.append([
                            "entry": fileMode ? "file-mode" : "mixed",
                            "scenario": scenario,
                            "round": round,
                            "input_to_publish_ms": published as Any? ?? NSNull(),
                            "input_to_draw_ms": drawing as Any? ?? NSNull(),
                            "outcome": drawing == nil ? "terminal-without-body" : "drawn",
                            "query_state": String(describing: data.service.queryState),
                            "quick_visible": fixture.model.quickSearch.isVisible,
                            "model_ready": data.service.modelReady,
                            "complete_ms": complete,
                            "main_actor_max_timer_gap_ms": gap,
                            "input_uptime": uptime,
                            "overlapping_batch": overlaps.first ?? [],
                            "completed_batches": observer.completed
                        ])
                        if round % 25 == 0 {
                            let chunks = try data.store.counts().chunks
                            #expect(
                                chunks >=
                                    Int(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")!,
                                "the synthetic base must not be re-extracted or pruned during contention"
                            )
                            rows[rows.count - 1]["indexed_chunks"] = chunks
                        }
                        try checkpoint()
                    }
                }
                if let speech = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_CONTENTION_SPEECH"],
                   let asrFolder = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_CONTENTION_ASR"] {
                    let speechURL = URL(fileURLWithPath: speech),
                        audio = try AVAudioFile(forReading: URL(fileURLWithPath: speech))
                    let duration = Double(audio.length) / audio.processingFormat.sampleRate
                    for condition in ["voice-idle", "voice-preempt-index"] {
                        data.service.pause(condition == "voice-idle")
                        stage = condition + "-readiness"
                        if condition == "voice-idle" {
                            try await wait { !observer.active }
                        }
                        for round in 0 ..< 10 {
                            if condition == "voice-preempt-index" {
                                try await wait { observer.active }
                            }
                            let active = observer.active, completed = observer.completed
                            // Drive the same foreground-busy boundary used by workflow recording/processing.
                            // The real CPU transcriber runs while a previously active index batch yields.
                            data.service.setForegroundBusy(true)
                            let startsAtVoiceBoundary = observer.startedBatches
                            let start = ContinuousClock.now
                            let transcription = Task {
                                try await SenseVoiceTranscriber(
                                    modelIdentifier: LocalSTTModel.senseVoiceSmall.defaultModelIdentifier,
                                    modelFolder: asrFolder
                                ).transcribe(audioFile: AudioFile(fileURL: speechURL, duration: duration))
                            }
                            let ftsStart = ContinuousClock.now
                            let hits = await data.service.search("reimbursement", type: .all, limit: 5)
                            let ftsMs = ms(ftsStart), transcript = try await transcription.value
                            let asrMs = ms(start)
                            let foundBody = hits.contains { $0.path == data.document.path }
                            let nonemptyTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if !foundBody {
                                failedBodySamples += 1
                            }
                            #expect(nonemptyTranscript)
                            #expect(foundBody)
                            let noNewCompletions = observer.completed <= completed + (active ? 1 : 0)
                            #expect(
                                noNewCompletions,
                                "only the already active batch may complete during foreground voice"
                            )
                            let noNewStarts = observer.startedBatches == startsAtVoiceBoundary
                            #expect(noNewStarts, "foreground voice must prevent a new index batch from starting")
                            rows.append(["entry": fileMode ? "file-mode" : "mixed", "scenario": condition,
                                         "round": round, "asr_ms": asrMs, "audio_seconds": duration,
                                         "fts_during_voice_ms": ftsMs, "index_active_at_voice_start": active,
                                         "transcript_nonempty": nonemptyTranscript, "fts_found_body": foundBody,
                                         "index_batches_before_voice": completed,
                                         "index_batches_after_voice": observer.completed,
                                         "no_new_completed_index_batch_during_voice": noNewCompletions,
                                         "index_batch_starts_at_voice_boundary": startsAtVoiceBoundary,
                                         "index_batch_starts_after_voice": observer.startedBatches,
                                         "no_new_index_batch_during_voice": noNewStarts])
                            data.service.setForegroundBusy(false)
                            try checkpoint()
                        }
                    }
                }
                // Cancel through real native edits, then close while a semantic request is pending.
                input.selectAll(nil); input.insertText(
                    "obsolete reimbursement",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                input.selectAll(nil); input.insertText(
                    "reimbursement",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                try await wait { settled("reimbursement") && drawn() }
                input.selectAll(nil); input.insertText(
                    "How can employees recover travel spending cancel",
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                fixture.model.quickSearch.setVisible(false); fixture.model.plugins.deactivate()
                fixture.model.resetSession(); window.orderOut(nil)
                try await Task.sleep(for: .milliseconds(400))
                #expect(fixture.model.quickSearch.results == nil && fixture.model.plugins.partial == nil)
                try entries.append(["entry": fileMode ? "file-mode" : "mixed", "completed_batches": observer.completed,
                                    "index_intervals": observer.intervals, "chunks_at_end": data.store.counts().chunks,
                                    "native_edit_and_close_cancellation": true, "disk_bytes": data.diskBytes,
                                    "load_seconds": data.loadSeconds,
                                    "successfully_embedded_texts": observer.successfulTexts])
                await data.clear()
            } catch {
                await data.clear(); throw error
            }
        }
        finished = true
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["rows": rows, "entries": entries, "complete": true,
                                     "failed_body_samples": failedBodySamples, "app_max_rss_bytes": usage.ru_maxrss,
                                     "model_sha256": SemanticModel.sha256,
                                     "initial_chunks": Int(ProcessInfo.processInfo
                                         .environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")!, "background_files": 512,
                                     "thermal_before": thermalBefore,
                                     "thermal_after": ProcessInfo.processInfo.thermalState.rawValue,
                                     "build": _isDebugAssertConfiguration() ? "Debug" : "Release",
                                     "index_inference_concurrency": 1,
                                     "scope": "Actual composer/native commits, production service/indexer, real background document embeddings and query model; base corpus is synthetic noise plus one real winning passage. Layout/display is not a GPU fence; timer gaps include polling/accessibility work."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to:
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "docs/validation/gul-383/optimization/ranking-scale/contention-\(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_LABEL"] ?? "after")-\(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000").json"
                ))
        #expect(failedBodySamples == 0, "terminal queries without the expected body remain failed samples")
    }
}
