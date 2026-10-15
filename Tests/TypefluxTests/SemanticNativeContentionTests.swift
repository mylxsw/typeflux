import AppKit
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
    var active: Bool { lock.withLock { started.count > finished.count } }
    var completed: Int { lock.withLock { finished.count } }
    var intervals: [[Double]] { lock.withLock { zip(started, finished).map { [$0, $1] } } }
    func begin() { lock.withLock { started.append(ProcessInfo.processInfo.systemUptime) } }
    func end() { lock.withLock { finished.append(ProcessInfo.processInfo.systemUptime) } }
}

private final class SemanticObservedEncoder: SemanticEmbedding {
    let worker: SemanticEmbeddingWorker
    let observer: SemanticInferenceObserver
    init(helper: URL, model: URL, observer: SemanticInferenceObserver) {
        worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true)
        self.observer = observer
    }
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        observer.begin(); defer { observer.end() }
        return try worker.embed(texts, cancelled: cancelled)
    }
    func release() { worker.release() }
}

@Suite("Native input during real document inference", .serialized, .exclusiveUIState)
@MainActor
struct SemanticNativeContentionTests {
    private func editor(in root: NSView) -> AskComposerTextView.Editor? {
        if let value = root as? AskComposerTextView.Editor { return value }
        return root.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test func measureBothEntriesDuringRealIndexingWhenRequested() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_CONTENTION_MODEL"] else { return }
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        var rows: [[String: Any]] = [], entries: [[String: Any]] = []
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        var timerGap = 0.0
        func ms(_ start: ContinuousClock.Instant) -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(45)
            var last = ContinuousClock.now
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
                timerGap = max(timerGap, ms(last)); last = .now
            }
            try #require(ready())
        }
        for fileMode in [false, true] {
            let observer = SemanticInferenceObserver()
            let data = try SemanticNativeBenchmarkData.make(model: URL(fileURLWithPath: model), makeEncoder: {
                SemanticObservedEncoder(helper: $0, model: $1, observer: observer)
            })
            do {
                try await wait { data.service.phase == .paused && data.service.modelReady }
                // Keep real documents available beyond the measured window, without a synthetic write loop.
                let background = String(repeating: "Basalt crystals beneath volcanic ridges. Quartz mineral formations. ", count: 800)
                for index in 0..<128 {
                    try background.write(to: data.root.appendingPathComponent("geology-\(index).txt"),
                                         atomically: true, encoding: .utf8)
                }
                data.service.pause(false)
                try await wait { data.service.phase == .indexing && observer.completed > 0 }
                data.service.prepareForSearch()
                try await wait { data.service.queryState != .warming }
                let fixture = try AskTestFixture(authenticated: false)
                defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
                fixture.model.semanticSearch = data.service; fixture.model.fileIndex = data.names
                if fileMode { fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0]) }
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
                    fileMode ? fixture.model.plugins.request?.text == text && fixture.model.plugins.output != nil :
                        fixture.model.quickSearch.isCurrent(text: text) && !fixture.model.quickSearch.isSearching
                }
                for scenario in ["fts-real-index", "semantic-real-index"] {
                    for round in 0..<100 {
                        if !input.string.isEmpty { input.selectAll(nil); input.deleteBackward(nil) }
                        try await wait { fixture.model.launcherDraft.text.isEmpty && !drawn() }
                        try await wait { observer.active }
                        let text = scenario == "fts-real-index" ? "reimbursement" :
                            "How can I get back money spent during business travel contention \(fileMode) \(round)"
                        if scenario == "semantic-real-index" {
                            #expect(try data.store.lexicalSearch(text: text, query: .init(text), type: .all,
                                scope: data.scope, limit: 5, cancelled: { false }).isEmpty)
                        }
                        // Lexical inspection precedes the timed active-batch boundary.
                        try await wait { observer.active }
                        timerGap = 0
                        let start = ContinuousClock.now, uptime = ProcessInfo.processInfo.systemUptime
                        let completedBeforeInput = observer.completed
                        var published: Double?
                        let watch: AnyCancellable
                        if fileMode {
                            watch = fixture.model.plugins.$partial.sink { value in
                                if published == nil, fixture.model.plugins.request?.text == text,
                                   value?.items.contains(where: { $0.fileHit?.path == data.document.path }) == true {
                                    published = ms(start)
                                }
                            }
                        } else {
                            watch = fixture.model.quickSearch.$results.sink { value in
                                if published == nil, fixture.model.quickSearch.isCurrent(text: text),
                                   value?.files.contains(where: { $0.path == data.document.path }) == true {
                                    published = ms(start)
                                }
                            }
                        }
                        input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                        try await wait { published != nil }
                        try await wait { drawn() }
                        let drawing = ms(start)
                        try await wait { settled(text) }
                        watch.cancel()
                        let complete = ms(start), gap = timerGap
                        try await wait { observer.completed > completedBeforeInput }
                        let overlaps = observer.intervals.filter { $0[0] <= uptime && $0[1] >= uptime }
                        #expect(overlaps.count == 1, "the input must overlap a real background inference")
                        rows.append(["entry": fileMode ? "file-mode" : "mixed", "scenario": scenario, "round": round,
                            "input_to_publish_ms": published!, "input_to_draw_ms": drawing, "complete_ms": complete,
                            "main_actor_max_timer_gap_ms": gap, "input_uptime": uptime,
                            "overlapping_batch": overlaps.first ?? [], "completed_batches": observer.completed])
                    }
                }
                // Cancel through real native edits, then close while a semantic request is pending.
                input.selectAll(nil); input.insertText("obsolete reimbursement", replacementRange: NSRange(location: NSNotFound, length: 0))
                input.selectAll(nil); input.insertText("reimbursement", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await wait { settled("reimbursement") && drawn() }
                input.selectAll(nil); input.insertText("How can employees recover travel spending cancel", replacementRange: NSRange(location: NSNotFound, length: 0))
                fixture.model.quickSearch.setVisible(false); fixture.model.plugins.deactivate()
                fixture.model.resetSession(); window.orderOut(nil)
                try await Task.sleep(for: .milliseconds(400))
                #expect(fixture.model.quickSearch.results == nil && fixture.model.plugins.partial == nil)
                entries.append(["entry": fileMode ? "file-mode" : "mixed", "completed_batches": observer.completed,
                    "index_intervals": observer.intervals, "chunks_at_end": try data.store.counts().chunks,
                    "native_edit_and_close_cancellation": true])
                await data.clear()
            } catch {
                await data.clear(); throw error
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["rows": rows, "entries": entries, "app_max_rss_bytes": usage.ru_maxrss,
            "model_sha256": SemanticModel.sha256, "initial_chunks": 100000, "background_files": 128,
            "thermal_before": thermalBefore, "thermal_after": ProcessInfo.processInfo.thermalState.rawValue,
            "build": _isDebugAssertConfiguration() ? "Debug" : "Release", "index_inference_concurrency": 1,
            "scope": "Actual composer/native commits, production service/indexer, real background document embeddings and query model; base corpus is synthetic noise plus one real winning passage. Layout/display is not a GPU fence; timer gaps include polling/accessibility work."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to:
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/validation/gul-383/optimization/native-inference-contention.json"))
    }
}
