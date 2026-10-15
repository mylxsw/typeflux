import Foundation
import Testing
@testable import Typeflux

/// Hold selected long-file batches so assertions observe scheduling, without timing model inference.
private final class FairnessBarrierEncoder: SemanticEmbedding, @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var calls = 0
    private var allowed = 0
    private var waiting = 0
    var blockedAt: Int {
        condition.withLock { waiting }
    }

    func arm() {
        condition.withLock { armed = true; calls = 0; allowed = 0 }
    }

    func allow(_ count: Int = Int.max) {
        condition.withLock { allowed = count; condition.broadcast() }
    }

    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        condition.lock()
        defer { condition.unlock() }
        if armed, texts[0].hasPrefix("title: long.txt") {
            calls += 1
            while calls > allowed, !cancelled() {
                waiting = calls
                _ = condition.wait(until: Date().addingTimeInterval(0.02))
            }
            waiting = 0
        }
        if cancelled() {
            throw CancellationError()
        }
        return texts.map { _ in semanticVector() }
    }
}

@Suite("Production reader and service incremental document fairness", .serialized, .exclusiveUIState)
@MainActor
struct SemanticIndexFairnessServiceTests {
    @Test func `ready service publishes new small document while changed long document is partial`() async throws {
        let root = try semanticFixture(), corpus = root.appendingPathComponent("corpus"),
            state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in [corpus, state] {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
        let file = corpus.appendingPathComponent("long.txt"), small = corpus.appendingPathComponent("small.txt")
        try "originalzebra".write(to: file, atomically: true, encoding: .utf8)
        let suite = "fairness-service-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var names = AskLauncherSearchSettings(); names.fileRoots = [corpus.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let source = root.appendingPathComponent("fixture-model")
        try Data("model".utf8).write(to: source)
        try FileManager.default.copyItem(at: source, to: state.appendingPathComponent("embeddinggemma-2-Q8_0.gguf"))
        let encoder = FairnessBarrierEncoder(), watcher = SemanticFixtureWatcher()
        let service = SemanticFileSearchService(settings: settings, directory: state,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: watcher,
                                                access: { true }, automaticStart: false, lowPowerMode: { false },
                                                thermalConstrained: { false },
                                                models: SemanticFixtureModels(source: source),
                                                makeReader: { AskFileReader() },
                                                makeEncoder: { _, _ in encoder },
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        func wait(_ ready: @MainActor () throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while try !ready(), ContinuousClock.now < deadline, service.phase != .failed {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(try ready(), "service phase: \(service.phase), blocked batch: \(encoder.blockedAt)")
        }
        do {
            #expect(service.setEnabled(true))
            try await wait { service.phase == .ready }
            let store = try SemanticFileStore(url: state.appendingPathComponent("semantic-files.sqlite"))
            encoder.arm()
            try (String(repeating: "updated project body ", count: 18000) + " longtailzebra").write(
                to: file,
                atomically: true,
                encoding: .utf8
            )
            watcher.change?([.init(path: file.path, rescan: false, isDirectory: false)], 1)
            try await wait { encoder.blockedAt == 1 }
            #expect(service.phase == .indexing)
            try "smallservicezebra".write(to: small, atomically: true, encoding: .utf8)
            watcher.change?([.init(path: small.path, rescan: false, isDirectory: false)], 2)
            // Deliver the main-actor watcher callback before letting the worker reach its next boundary.
            try await Task.sleep(for: .milliseconds(30))
            encoder.allow(2)
            try await wait { try encoder.blockedAt == 3 && store.job(small.path)?.state == .done }
            #expect(try store.job(file.path)?.state == .partial)
            #expect(try store.lexicalSearch(
                text: "smallservicezebra",
                query: .init("smallservicezebra"),
                type: .all,
                scope: semanticScope(corpus.path),
                limit: 5,
                cancelled: { false }
            ).map(\.path) == [small.path])
            #expect(try store.search(vector: semanticVector(), text: "unrelated", query: .init("unrelated"),
                                     type: .all, scope: semanticScope(corpus.path), limit: 5, cancelled: { false })
                    .contains { $0.path == small.path })
            #expect(await service.search("smallservicezebra", type: .all, limit: 5).contains { $0.path == small.path })
            encoder.allow()
            try await wait { service.phase == .ready }
            #expect(try store.job(file.path)?.state == .done)
            #expect(try store.counts().files == 2)
        } catch {
            encoder.allow()
            await service.clear(removeModel: true)
            throw error
        }
        await service.clear(removeModel: true)
    }
}
