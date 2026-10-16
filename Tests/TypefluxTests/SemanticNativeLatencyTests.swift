import AppKit
import Combine
import Darwin
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Native composer semantic latency", .serialized, .exclusiveUIState)
@MainActor
struct SemanticNativeLatencyTests {
    private func editor(in root: NSView) -> AskComposerTextView.Editor? {
        if let editor = root as? AskComposerTextView.Editor {
            return editor
        }
        return root.subviews.lazy.compactMap { editor(in: $0) }.first
    }
}

extension SemanticNativeLatencyTests {
    @Test func `measure committed native input to body publication and drawing when requested`() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL"] else { return }
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        var rows: [[String: Any]] = [], corpus: [[String: Any]] = []
        var failedBodySamples = 0
        var timerGap = 0.0
        let environment = ProcessInfo.processInfo.environment
        let largeScale = environment["TYPEFLUX_SEMANTIC_SCALE"] == "1000000"
        let warmSamples = largeScale ? 20 : 100
        let selectedEntry = environment["TYPEFLUX_SEMANTIC_ENTRY"]
        let selectedScenario = environment["TYPEFLUX_SEMANTIC_SCENARIO"]
        let scenarios = ["cold", "fts-cache", "semantic-cache", "hot-new-semantic", "index-writer"]
        try #require(try selectedEntry == nil || ["mixed", "file-mode"].contains(#require(selectedEntry)))
        let availableScenarios = scenarios + ["cold-fts"]
        try #require(try selectedScenario == nil || availableScenarios.contains(#require(selectedScenario)))
        let selectedScenarios = selectedScenario.map { [$0] } ?? scenarios
        let suffix = environment["TYPEFLUX_SEMANTIC_TAG"].map { "-" + $0 } ?? ""
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "docs/validation/gul-383/optimization/ranking-scale/native-\(environment["TYPEFLUX_SEMANTIC_LABEL"] ?? "after")-\(environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")\(suffix)"
            )
        var stage = "setup", complete = false, savedFailure = false
        var debugState: @MainActor () -> [String: Any] = { [:] }
        func checkpoint() throws {
            guard !savedFailure else { return }
            try JSONSerialization.data(withJSONObject: ["rows": rows, "corpus": corpus, "stage": stage,
                                                        "complete": complete, "state": debugState()],
                                       options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output.path + ".partial.json"))
        }
        defer { try? checkpoint() }
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(largeScale ? 120 : 30)
            var last = ContinuousClock.now
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
                timerGap = max(timerGap, milliseconds(last)); last = .now
            }
            let reached = ready()
            if !reached {
                try? checkpoint(); savedFailure = true
            }
            try #require(reached, "Native benchmark wait failed at \(stage)")
        }
        for fileMode in [false, true]
            where selectedEntry == nil || selectedEntry == (fileMode ? "file-mode" : "mixed") {
            let entry = fileMode ? "file-mode" : "mixed"
            stage = "setup-" + entry
            let data = try SemanticNativeBenchmarkData.make(model: URL(fileURLWithPath: model))
            do {
                stage = "readiness-" + entry
                try await wait { data.service.phase == .ready && data.service.modelReady }
                data.service.pause(true)
                try #require(
                    try data.store.counts()
                        .chunks == Int(ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000"),
                    "Startup must retain every seeded scale row"
                )
                if environment["TYPEFLUX_SEMANTIC_DENY_DOCUMENT"] == "1" {
                    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: data.document.path)
                }
                let fixture = try AskTestFixture(authenticated: false)
                let diagnostic = environment["TYPEFLUX_SEMANTIC_TRACE"] == "1"
                    ? SemanticNativeTraceService(service: data.service) : nil
                if let diagnostic {
                    fixture.model.semanticSearch = diagnostic
                } else {
                    fixture.model.semanticSearch = data.service
                }
                fixture.model.fileIndex = data.names
                if fileMode {
                    fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0])
                }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: AskComposer(model: fixture.model, launcher: true).padding(20))
                host.sizingOptions = []
                window.contentView = host; window.orderFront(nil)
                defer {
                    window.close(); fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root)
                }
                stage = "editor-" + entry
                try await wait { editor(in: host) != nil }
                let input = try #require(editor(in: host))
                debugState = {
                    ["phase": String(describing: data.service.phase),
                     "query_state": String(describing: data.service.queryState),
                     "draft": fixture.model.launcherDraft.text, "editor": input.string,
                     "quick_searching": fixture.model.quickSearch.isSearching,
                     "quick_visible": fixture.model.quickSearch.isVisible,
                     "model_ready": data.service.modelReady,
                     "diagnostic_trace": diagnostic?.recorder.events ?? [],
                     "plugin_request": fixture.model.plugins.request?.text as Any? ?? NSNull(),
                     "plugin_output": fixture.model.plugins.output != nil]
                }
                func hasDrawnBody() -> Bool {
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    return SettingsBehaviorTestSupport.elements(in: host).contains {
                        $0.text.contains("handbook.txt") || $0.label.contains("handbook.txt")
                    }
                }
                func settled(_ text: String) -> Bool {
                    fileMode ? fixture.model.plugins.isPlanCurrent && fixture.model.plugins.request?.text == text
                        && fixture.model.plugins.output != nil
                        : fixture.model.quickSearch.isCurrent(text: text) && !fixture.model.quickSearch.isSearching
                }
                for scenario in selectedScenarios {
                    let cold = scenario == "cold" || scenario == "cold-fts"
                    stage = "prewarm-" + entry + "-" + scenario
                    if !cold {
                        data.service.prepareForSearch()
                        try await wait { data.service.queryState != .warming }
                    }
                    let stop = AskSearchCancellation(), store = data.store, root = data.root,
                        vector = data.backgroundVector
                    defer { stop.cancel() }
                    let writer: Task<Void, Error>? = scenario == "index-writer" ? Task.detached {
                        while !stop.isCancelled {
                            try store.replace(path: root.path + "/writer.txt", modified: Date(), bytes: 1,
                                              chunks: [.init(text: "background", page: nil)], vectors: [vector])
                            try await Task.sleep(for: .milliseconds(10))
                        }
                    } : nil
                    do {
                        for round in 0 ..< (cold ? 10 : warmSamples) {
                            let sample = "\(entry)-\(scenario)-\(round)"
                            stage = "clear-" + sample
                            if !input.string.isEmpty {
                                input.selectAll(nil); input.deleteBackward(nil)
                            }
                            try await wait {
                                fixture.model.launcherDraft.text.isEmpty && !hasDrawnBody() && settled("")
                            }
                            if cold && (round > 0 || scenario == "cold-fts") {
                                stage = "cold-reopen-" + sample
                                data.service.endSearch(); data.service.pause(false); data.service.start(force: true)
                                try await wait { data.service.phase == .ready && data.service.modelReady }
                                data.service.pause(true)
                            }
                            let text = if scenario == "fts-cache" || scenario == "index-writer" || scenario ==
                                "cold-fts" {
                                "reimbursement"
                            } else if scenario == "semantic-cache" {
                                "How can I get back money spent during business travel cached native \(fileMode)"
                            } else {
                                "How can I get back money spent during business travel native \(fileMode) \(scenario) \(round)"
                            }
                            if scenario == "hot-new-semantic" || scenario == "semantic-cache" {
                                #expect(try store.lexicalSearch(
                                    text: text,
                                    query: .init(text),
                                    type: .all,
                                    scope: data.scope,
                                    limit: 5,
                                    cancelled: { false }
                                ).isEmpty)
                            }
                            timerGap = 0
                            diagnostic?.recorder.reset()
                            let start = ContinuousClock.now
                            var published: Double?
                            let watch: AnyCancellable = if fileMode {
                                fixture.model.plugins.$partial.sink { value in
                                    if published == nil, fixture.model.plugins.request?.text == text,
                                       value?.items
                                       .contains(where: { $0.fileHit?.path == data.document.path }) == true {
                                        published = milliseconds(start)
                                    }
                                }
                            } else {
                                fixture.model.quickSearch.$results.sink { value in
                                    if published == nil, fixture.model.quickSearch.isCurrent(text: text),
                                       value?.files.contains(where: { $0.path == data.document.path }) == true {
                                        published = milliseconds(start)
                                    }
                                }
                            }
                            input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                            stage = "publish-" + sample
                            try await wait { published != nil || settled(text) }
                            var drawn: Double?
                            if published != nil {
                                stage = "draw-" + sample
                                try await wait { hasDrawnBody() }
                                drawn = milliseconds(start)
                            } else {
                                failedBodySamples += 1
                            }
                            stage = "settle-" + sample
                            try await wait { settled(text) }
                            watch.cancel()
                            rows.append([
                                "entry": fileMode ? "file-mode" : "mixed",
                                "scenario": scenario,
                                "round": round,
                                "input_to_publish_ms": published as Any? ?? NSNull(),
                                "input_to_draw_ms": drawn as Any? ?? NSNull(),
                                "outcome": drawn == nil ? "terminal-without-body" : "drawn",
                                "query_state": String(describing: data.service.queryState),
                                "quick_visible": fixture.model.quickSearch.isVisible,
                                "model_ready": data.service.modelReady,
                                "trace": diagnostic?.recorder.events ?? [],
                                "complete_ms": milliseconds(start),
                                "main_actor_max_timer_gap_ms": timerGap,
                                "input_uptime": ProcessInfo.processInfo.systemUptime - milliseconds(start) / 1000
                            ])
                            if round % 10 == 0 {
                                try checkpoint()
                            }
                        }
                        stop.cancel(); try await writer?.value
                    } catch {
                        stop.cancel(); try? await writer?.value; throw error
                    }
                }
                fixture.model.quickSearch.cancel(); fixture.model.plugins.deactivate()
                try corpus.append(["entry": fileMode ? "file-mode" : "mixed", "disk_bytes": data.diskBytes,
                                   "noise_vector_source": data.noiseVectorSource,
                                   "load_seconds": data.loadSeconds, "chunks": data.store.counts().chunks])
                debugState = { [:] }
                await data.clear()
            } catch {
                try? checkpoint()
                debugState = { [:] }
                await data.clear(); throw error
            }
        }
        complete = true
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["rows": rows,
                                     "complete": true,
                                     "failed_body_samples": failedBodySamples,
                                     "entry_scope": selectedEntry ?? "all",
                                     "warm_samples_per_scenario": warmSamples,
                                     "permission_denial_fixture": environment["TYPEFLUX_SEMANTIC_DENY_DOCUMENT"] == "1",
                                     "scenario_scope": selectedScenario ?? "all",
                                     "corpus": corpus,
                                     "app_max_rss_bytes": usage.ru_maxrss,
                                     "model_sha256": SemanticModel.sha256,
                                     "chunks": Int(ProcessInfo.processInfo
                                         .environment["TYPEFLUX_SEMANTIC_SCALE"] ?? "100000")!,
                                     "indexed_files": 2,
                                     "scope": "Actual AskComposer, native NSTextView commit, production mixed/f sessions and service, real model and permission helper. Drawing forces layout/display and checks rendered accessibility; it is not a GPU presentation fence.",
                                     "build": _isDebugAssertConfiguration() ? "Debug" : "Release",
                                     "index_writer_concurrency": selectedScenarios.contains("index-writer") ? 1 : 0,
                                     "index_inference_concurrency": 0,
                                     "cold_definition": "Ten fresh service/helper openings per entry; OS/model/shader caches may be warm; opening the panel requests prewarming. Reopen and model verification occur outside the timed native edit."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output.path + ".json"))
        #expect(failedBodySamples == 0, "terminal queries without the expected body remain failed samples")
    }
}

/// Opt-in diagnostic forwarding keeps the production provider and all timed UI boundaries intact.
private final class SemanticNativeTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var start = ProcessInfo.processInfo.systemUptime
    private var stored: [[String: Any]] = []
    var events: [[String: Any]] {
        lock.withLock { stored }
    }

    func reset() {
        lock.withLock { start = ProcessInfo.processInfo.systemUptime; stored = [] }
    }

    func record(_ event: SemanticSearchTrace.Event) {
        lock.withLock {
            stored.append(["stage": event.stage, "value_ms": event.milliseconds, "duration": event.duration,
                           "input_elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
        }
    }
}

@MainActor
private final class SemanticNativeTraceService: SemanticFileSearching {
    let service: SemanticFileSearchService
    let recorder = SemanticNativeTraceRecorder()
    init(service: SemanticFileSearchService) {
        self.service = service
    }

    var isEnabled: Bool {
        service.isEnabled
    }

    func prepareForSearch() {
        service.prepareForSearch()
    }

    func endSearch() {
        service.endSearch()
    }

    func search(_ text: String, type: AskFileType, limit: Int) async -> [AskFileHit] {
        await search(text, type: type, limit: limit, progress: { _ in })
    }

    func search(_ text: String, type: AskFileType, limit: Int,
                progress: @escaping @MainActor @Sendable ([AskFileHit]) -> Void) async -> [AskFileHit] {
        let recorder = recorder
        let trace = SemanticSearchTrace(sink: { recorder.record($0) })
        trace.mark("diagnostic-provider-entered")
        let hits = await SemanticSearchTrace.$current.withValue(trace) {
            await service.search(text, type: type, limit: limit, progress: progress)
        }
        trace.mark("diagnostic-provider-returned")
        return hits
    }
}
