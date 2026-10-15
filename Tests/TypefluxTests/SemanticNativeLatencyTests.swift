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
        if let editor = root as? AskComposerTextView.Editor { return editor }
        return root.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @Test func measureCommittedNativeInputToBodyPublicationAndDrawingWhenRequested() async throws {
        guard let model = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_NATIVE_BENCH_MODEL"] else { return }
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        var rows: [[String: Any]] = []
        var timerGap = 0.0
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let parts = start.duration(to: .now).components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(30)
            var last = ContinuousClock.now
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
                timerGap = max(timerGap, milliseconds(last)); last = .now
            }
            try #require(ready())
        }
        for fileMode in [false, true] {
            let data = try SemanticNativeBenchmarkData.make(model: URL(fileURLWithPath: model))
            try await wait { data.service.phase == .paused && data.service.modelReady }
            let fixture = try AskTestFixture(authenticated: false)
            fixture.model.semanticSearch = data.service
            fixture.model.fileIndex = data.names
            if fileMode { fixture.model.plugins.enter(AskFileSearchPlugin.keywords[0]) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: AskComposer(model: fixture.model, launcher: true).padding(20))
            host.sizingOptions = []
            window.contentView = host; window.orderFront(nil)
            defer { window.close(); fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
            try await wait { editor(in: host) != nil }
            let input = try #require(editor(in: host))
            func hasDrawnBody() -> Bool {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                return SettingsBehaviorTestSupport.elements(in: host).contains {
                    $0.text.contains("handbook.txt") || $0.label.contains("handbook.txt")
                }
            }
            for scenario in ["cold", "fts-cache", "hot-new-semantic", "index-writer"] {
                if scenario != "cold" {
                    data.service.prepareForSearch()
                    try await wait { data.service.queryState != .warming }
                }
                let stop = AskSearchCancellation(), store = data.store, root = data.root, vector = data.backgroundVector
                defer { stop.cancel() }
                let writer: Task<Void, Error>? = scenario == "index-writer" ? Task.detached {
                    while !stop.isCancelled {
                        try store.replace(path: root.path + "/writer.txt", modified: Date(), bytes: 1,
                                          chunks: [.init(text: "background", page: nil)], vectors: [vector])
                        try await Task.sleep(for: .milliseconds(10))
                    }
                } : nil
                for round in 0..<(scenario == "cold" ? 1 : 100) {
                    if !input.string.isEmpty { input.selectAll(nil); input.deleteBackward(nil) }
                    try await wait {
                        fixture.model.launcherDraft.text.isEmpty && !hasDrawnBody()
                            && (fileMode ? fixture.model.plugins.request?.text == "" && fixture.model.plugins.output != nil
                                : !fixture.model.quickSearch.isSearching)
                    }
                    let text = scenario == "fts-cache" || scenario == "index-writer" ? "reimbursement" :
                        "How can I get back money spent during business travel native \(fileMode) \(scenario) \(round)"
                    if scenario == "hot-new-semantic" {
                        #expect(try store.lexicalSearch(text: text, query: .init(text), type: .all, scope: data.scope,
                                                       limit: 5, cancelled: { false }).isEmpty)
                    }
                    timerGap = 0
                    let start = ContinuousClock.now
                    var published: Double?
                    let watch: AnyCancellable
                    if fileMode {
                        watch = fixture.model.plugins.$partial.sink { value in
                            if published == nil, fixture.model.plugins.request?.text == text,
                               value?.items.contains(where: { $0.fileHit?.path == data.document.path }) == true {
                                published = milliseconds(start)
                            }
                        }
                    } else {
                        watch = fixture.model.quickSearch.$results.sink { value in
                            if published == nil, fixture.model.quickSearch.isCurrent(text: text),
                               value?.files.contains(where: { $0.path == data.document.path }) == true {
                                published = milliseconds(start)
                            }
                        }
                    }
                    input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await wait { published != nil }
                    try await wait { hasDrawnBody() }
                    let drawn = milliseconds(start)
                    try await wait {
                        fileMode ? fixture.model.plugins.request?.text == text && fixture.model.plugins.output != nil
                            : fixture.model.quickSearch.isCurrent(text: text) && !fixture.model.quickSearch.isSearching
                    }
                    watch.cancel()
                    rows.append(["entry": fileMode ? "file-mode" : "mixed", "scenario": scenario, "round": round,
                                 "input_to_publish_ms": published!, "input_to_draw_ms": drawn,
                                 "complete_ms": milliseconds(start), "main_actor_max_timer_gap_ms": timerGap])
                }
                stop.cancel(); try await writer?.value
            }
            fixture.model.quickSearch.cancel(); fixture.model.plugins.deactivate()
            await data.clear()
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["rows": rows, "app_max_rss_bytes": usage.ru_maxrss,
            "model_sha256": SemanticModel.sha256, "chunks": 100000, "indexed_files": 2,
            "scope": "Actual AskComposer, native NSTextView commit, production mixed/f sessions and service, real model and permission helper. Drawing forces layout/display and checks rendered accessibility; it is not a GPU presentation fence.",
            "build": _isDebugAssertConfiguration() ? "Debug" : "Release", "index_writer_concurrency": 1,
            "index_inference_concurrency": 0, "cold_definition": "Fresh helper; OS/model/shader caches may be warm; opening the panel requests prewarming" ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to:
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("docs/validation/gul-383/optimization/native-publication-latency.json"))
    }
}
