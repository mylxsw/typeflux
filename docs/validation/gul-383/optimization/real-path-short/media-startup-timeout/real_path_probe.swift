import AppKit
import Combine
import Foundation
import SwiftUI
@testable import Typeflux
@testable import TypefluxFocusedTests

/// Opt-in evidence tool. All inputs, defaults and model copies belong to its private root.
@main @MainActor
struct RealPathProbe {
    struct ProbeFailure: Error { let message: String }
    static var report: [String: Any] = ["complete": false]
    static var output: URL!

    static func save() throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output, options: .atomic)
    }

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw ProbeFailure(message: message) }
    }

    static func wait(_ label: String, seconds: Double = 180, _ ready: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !ready(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(ready(), "Timeout: " + label)
    }

    static func milliseconds(_ start: Double) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    static func row(_ hit: AskFileHit) -> [String: Any] {
        ["name": hit.name, "source": hit.evidence?.segmentKind as Any? ?? NSNull(),
         "snippet": hit.evidence?.text as Any? ?? NSNull(), "page": hit.evidence?.page as Any? ?? NSNull(),
         "time": hit.evidence?.time as Any? ?? NSNull(), "chunk_id": hit.evidence?.chunkID as Any? ?? NSNull(),
         "has_version": hit.evidence?.version != nil, "score": hit.score]
    }

    static func resourceWindow(service: SemanticFileSearchService, corpus: URL, seconds: Double) async throws {
        let began = ProcessInfo.processInfo.systemUptime
        var rows: [[String: Any]] = []
        report["resource_started_uptime"] = began
        try save()
        // The parent starts the existing independent own-window event/frame probe now.
        let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", prepare: { model in
            model.semanticSearch = service
            model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
            var names = model.modelLibrary.settings.askLauncherSearchSettings
            names.fileRoots = [corpus.path]; names.excludedPaths = []
            model.modelLibrary.settings.askLauncherSearchSettings = names
        })
        defer { launcher.close() }
        var sample = 0
        while ProcessInfo.processInfo.systemUptime - began < seconds {
            try "Synthetic indexing progress voucher BACKGROUND-\(sample).".write(
                to: corpus.appendingPathComponent("background-\(sample).txt"), atomically: true, encoding: .utf8)
            launcher.editor.selectAll(nil); launcher.editor.deleteBackward(nil)
            try await Task.sleep(for: .milliseconds(50))
            let start = ProcessInfo.processInfo.systemUptime
            launcher.editor.insertText("ERR-739204", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await wait("resource native result", seconds: 15) {
                launcher.fixture.model.quickSearch.isCurrent(text: "ERR-739204") &&
                    launcher.fixture.model.quickSearch.results?.files.contains { $0.name == "screen.png" } == true
            }
            let view = launcher.window.contentView!
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            rows.append(["sample": sample, "elapsed_seconds": ProcessInfo.processInfo.systemUptime - began,
                "input_to_layout_ms": milliseconds(start), "files": service.files, "chunks": service.chunks,
                "phase": String(describing: service.phase)])
            report["resource_rows"] = rows; try save()
            sample += 1
            let remaining = seconds - (ProcessInfo.processInfo.systemUptime - began)
            if remaining > 0 { try await Task.sleep(for: .milliseconds(Int64(min(10, remaining) * 1000))) }
        }
        report["resource_duration_seconds"] = ProcessInfo.processInfo.systemUptime - began
        try save()
    }

    static func main() async {
        let env = ProcessInfo.processInfo.environment
        output = URL(fileURLWithPath: env["GUL405_REPORT"]!)
        let root = URL(fileURLWithPath: env["GUL405_PRIVATE_ROOT"]!)
        let corpus = root.appendingPathComponent("corpus")
        let directory = root.appendingPathComponent("models")
        let suite = "gul405-real-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        var names = AskLauncherSearchSettings()
        names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let executable = URL(fileURLWithPath: env["GUL405_FILE_HELPER"]!)
        let helper = URL(fileURLWithPath: env["GUL405_MODEL_HELPER"]!)
        let service = SemanticFileSearchService(settings: settings, directory: directory, helper: helper,
            supported: true, access: { true }, automaticStart: false,
            lowPowerMode: { false }, thermalConstrained: { false }, idle: { true },
            makeReader: { AskFileReader(executable: executable, timeout: 30) })
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.english)
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAX = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(true, forAttribute: ax)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            report["scope"] = "Synthetic fixed fixtures; real pinned text/media embeddings, production FSEvents/index/service and native editor/layout. Debug, small corpus; excludes physical HID and compositor fence, release/large-scale/long stability."
            try require(service.setEnabled(true), "Cannot enable isolated service")
            try await wait("initial indexing", seconds: 240) { service.phase == .ready }
            try require(service.files > 0 && service.chunks > 0, "Initial index is empty")
            report["initial_index_ms"] = milliseconds(start)
            report["initial_files"] = service.files
            report["initial_chunks"] = service.chunks
            report["phase"] = String(describing: service.phase)
            try save()
            let requests = [("INV-682914", "body.docx"), ("INV-739204", "scan.pdf"),
                            ("ERR-739204", "screen.png"), ("red screen", "scene.mov")]
            var queries: [[String: Any]] = []
            for (text, target) in requests {
                let began = ProcessInfo.processInfo.systemUptime
                let hits = await service.search(text, type: .all, limit: 5)
                queries.append(["query": text, "target": target, "found": hits.contains { $0.name == target },
                    "service_ms": milliseconds(began), "hits": hits.map(row)])
                report["queries"] = queries; try save()
            }
            // No fixed vectors are injected. The query backend is the production SemanticEmbeddingWorker.
            service.prepareForSearch()
            try await wait("query warmup") { service.queryState != .warming }
            var native: [[String: Any]] = []
            for files in [false, true] {
                let launcher = try await AskQuickResultsInteractionTests.Launcher(text: "", prepare: { model in
                    model.semanticSearch = service
                    model.modelLibrary.settings.semanticFileSearch = .init(enabled: true)
                    model.modelLibrary.settings.askLauncherSearchSettings = names
                    model.fileExists = { FileManager.default.fileExists(atPath: $0) }
                    if files { model.plugins.enter(AskFileSearchPlugin.keywords[0]) }
                })
                do {
                    let text = "ERR-739204", target = "screen.png"
                    let began = ProcessInfo.processInfo.systemUptime
                    var published: Double?
                    let watch: AnyCancellable = files ? launcher.fixture.model.plugins.$partial.sink { value in
                        if published == nil, value?.items.contains(where: { $0.fileHit?.name == target }) == true {
                            published = milliseconds(began)
                        }
                    } : launcher.fixture.model.quickSearch.$results.sink { value in
                        if published == nil, value?.files.contains(where: { $0.name == target }) == true {
                            published = milliseconds(began)
                        }
                    }
                    launcher.editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await wait("native result", seconds: 40) { published != nil }
                    let view = launcher.window.contentView!
                    try await wait("native drawing", seconds: 15) {
                        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                        return SettingsBehaviorTestSupport.elements(in: view).contains {
                            $0.text.contains(target) || $0.label.contains(target)
                        }
                    }
                    let drawn = milliseconds(began)
                    let hits = files ? launcher.fixture.model.plugins.partial?.items.compactMap(\.fileHit) ?? []
                        : launcher.fixture.model.quickSearch.results?.files ?? []
                    native.append(["entry": files ? "files" : "mixed", "input": launcher.editor.string,
                        "draft": launcher.fixture.model.launcherDraft.text, "input_to_publish_ms": published!,
                        "input_to_layout_ax_ms": drawn, "hits": hits.map(row)])
                    watch.cancel()
                    launcher.close()
                } catch {
                    launcher.close(); throw error
                }
                report["native"] = native; try save()
            }
            // Live file writes are observed through the real FSEvents watcher, never a manual index call.
            let eventStart = ProcessInfo.processInfo.systemUptime
            try "Voucher UPDATE-482917 approved for the synthetic project.".write(
                to: corpus.appendingPathComponent("event.txt"), atomically: true, encoding: .utf8)
            var eventHits: [AskFileHit] = []
            let deadline = eventStart + 45
            while eventHits.isEmpty, ProcessInfo.processInfo.systemUptime < deadline {
                eventHits = await service.search("UPDATE-482917", type: .all, limit: 5)
                if eventHits.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
            }
            report["file_event"] = ["write_to_matching_service_result_ms": milliseconds(eventStart), "hits": eventHits.map(row)]
            try require(!eventHits.isEmpty, "FSEvents write never became searchable")
            try await wait("event vectors") { service.phase == .ready }
            let afterEvent = await service.search("UPDATE-482917", type: .all, limit: 5)
            report["event_real_model_hits"] = afterEvent.map(row)
            service.pause(true)
            let reopened = try SemanticFileStore(url: directory.appendingPathComponent("semantic-files.sqlite"))
            let queryWorker = SemanticEmbeddingWorker(helper: helper, model: service.modelURL)
            defer { queryWorker.stop() }
            let vector = try await queryWorker.query("INV-682914", lifecycle: AskSearchCancellation())
            let persisted = try reopened.search(vector: vector, text: "INV-682914", query: .init("INV-682914"),
                type: .all, scope: semanticScope(corpus.path), limit: 5, cancelled: { false })
            report["reopened_real_model_hits"] = persisted.map(row)
            try require(persisted.contains { $0.name == "body.docx" }, "Reopened index lost Office body")
            try require(queries.prefix(3).allSatisfy { $0["found"] as? Bool == true }, "Required body/OCR fixture missing")
            service.pause(false)
            if let seconds = env["GUL405_RESOURCE_SECONDS"].flatMap(Double.init), seconds > 0 {
                try await resourceWindow(service: service, corpus: corpus, seconds: seconds)
            }
            report["final_files"] = service.files; report["final_chunks"] = service.chunks
            report["complete"] = true
        } catch {
            report["error"] = String(describing: error)
        }
        // Disable and join every owned writer before the parent removes this private root.
        service.endSearch()
        await service.clear()
        defaults.removePersistentDomain(forName: suite)
        AppLocalization.shared.setLanguage(previousLanguage)
        NSApp.accessibilitySetValue(previousAX ?? false, forAttribute: ax)
        report["wall_seconds"] = ProcessInfo.processInfo.systemUptime - start
        report["cleaned_up"] = true
        try? save()
        if report["complete"] as? Bool != true { exit(1) }
    }
}
