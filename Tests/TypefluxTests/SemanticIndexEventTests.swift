import Foundation
import Testing
@testable import Typeflux

private final class IndexEventWatcher: AskFileWatching, @unchecked Sendable {
    private let watcher = AskFSEventsWatcher(), lock = NSLock()
    private var times: [String: Double] = [:]
    func time(_ path: String) -> Double? {
        lock.withLock { times[path] }
    }

    func start(paths: [String], since: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        watcher.start(paths: paths, since: since) { [self] changes, id in
            lock.withLock {
                for change in changes where times[change.path] == nil {
                    times[change.path] = ProcessInfo.processInfo.systemUptime
                }
            }
            onChange(changes, id)
        }
    }

    func stop() {
        watcher.stop()
    }
}

@Suite("Real FSEvents to persisted body and vectors", .serialized, .exclusiveUIState)
@MainActor
struct SemanticIndexEventTests {
    @Test func `small documents use real events and real model when requested`() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["TYPEFLUX_INDEX_EVENT_MODEL"], let helper = env["TYPEFLUX_INDEX_EVENT_HELPER"],
              let report = env["TYPEFLUX_INDEX_EVENT_REPORT"] else { return }
        let root = try semanticFixture(), corpus = root.appendingPathComponent("corpus"),
            state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [corpus, state] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.linkItem(
            at: URL(fileURLWithPath: model),
            to: state.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        )
        let suite = "event-recovery-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var names = AskLauncherSearchSettings(); names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let watcher = IndexEventWatcher()
        let service = SemanticFileSearchService(
            settings: settings,
            directory: state,
            helper: URL(fileURLWithPath: helper),
            supported: true,
            watcher: watcher,
            access: { true },
            automaticStart: false,
            lowPowerMode: { false },
            thermalConstrained: { false }
        )
        #expect(service.setEnabled(true))
        func wait(_ ready: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(120)
            while !ready(), service.phase != .failed, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(ready(), "index phase: \(service.phase)")
        }
        try await wait { service.phase == .ready }
        let store = try SemanticFileStore(url: state.appendingPathComponent("semantic-files.sqlite"))
        var rows: [[String: Double]] = []
        for sample in 0 ..< 30 {
            let file = corpus.appendingPathComponent("event-\(sample).txt"), token = "eventzebra\(sample)"
            let written = ProcessInfo.processInfo.systemUptime
            try "Project reimbursement event \(token).".write(to: file, atomically: true, encoding: .utf8)
            try await wait { watcher.time(file.path) != nil }
            let event = try #require(watcher.time(file.path))
            var lexical = false
            let deadline = ContinuousClock.now + .seconds(120)
            while !lexical, ContinuousClock.now < deadline, service.phase != .failed {
                lexical = try store.lexicalSearch(text: token, query: .init(token), type: .all,
                                                  scope: semanticScope(corpus.path), limit: 1, cancelled: { false })
                    .first?.path == file.path
                if !lexical {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            try #require(lexical)
            let fts = ProcessInfo.processInfo.systemUptime
            try await wait { (try? store.job(file.path)?.state) == .done }
            let vector = ProcessInfo.processInfo.systemUptime
            rows.append(["sample": Double(sample), "write_to_event_ms": (event - written) * 1000,
                         "event_to_fts_ms": (fts - event) * 1000, "event_to_vectors_ms": (vector - event) * 1000,
                         "write_to_fts_ms": (fts - written) * 1000, "write_to_vectors_ms": (vector - written) * 1000])
            try await wait { service.phase == .ready }
        }
        // Mutate, rename, delete and replay through production FSEvents; old evidence cannot escape.
        let old = corpus.appendingPathComponent("event-0.txt"), renamed = corpus.appendingPathComponent("renamed.txt")
        try "changedzebra".write(to: old, atomically: true, encoding: .utf8)
        try await wait {
            (try? store.job(old.path)?.version) != nil && (try? store.job(old.path)?.version) != "" && service
                .phase == .ready
        }
        // The dedicated deterministic tests verify timing races; here poll for the new lexical token.
        var changed = false
        let deadline = ContinuousClock.now + .seconds(30)
        while !changed, ContinuousClock.now < deadline {
            changed = try !store.lexicalSearch(text: "changedzebra", query: .init("changedzebra"), type: .all,
                                               scope: semanticScope(corpus.path), limit: 5, cancelled: { false })
                .isEmpty
            if !changed {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(changed)
        try FileManager.default.moveItem(at: old, to: renamed)
        try await wait { (try? store.job(renamed.path)?.state) == .done }
        try FileManager.default.removeItem(at: renamed)
        try await wait { (try? store.counts().files) == 29 && service.phase == .ready }
        let payload: [String: Any] = ["samples": rows,
                                      "model_sha256": SemanticModel.sha256,
                                      "configuration": "Debug coverage app; Release native helper; serial small-file arrivals, no backlog; real FSEvents, production service and file worker; one writer, 30 files, one chunk/file",
                                      "measurement": "index publication visibility, not query latency or native UI rendering; 2ms polling resolution",
                                      "functional": ["rewrite": changed, "rename": true, "delete": true]]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: report))
        await service.clear(removeModel: false)
    }
}
