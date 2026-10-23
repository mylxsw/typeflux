import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureBackgroundRuntimeTests {
    @Test func `bounded index requests and settings remain usable without application DI`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "feature-background-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        let names = AskFileIndex(
            configuration: { (false, .init()) },
            snapshotURL: root.appendingPathComponent("files.bin"),
            defaults: defaults
        )
        let content = SemanticFileSearchService(
            settings: settings,
            directory: root,
            supported: false,
            automaticStart: false
        )
        let runtime = FeatureBackgroundRuntime(names: names, content: content)
        func call(_ action: String, _ input: some Encodable) async throws -> Data {
            try await runtime.handle(.init(
                destination: .background,
                action: action,
                payload: JSONEncoder().encode(input)
            ))
        }
        for action in [
            "ping",
            "settings",
            "files.start",
            "files.clear",
            "files.rebuild",
            "semantic.start",
            "semantic.pause",
            "semantic.busy.voice",
            "semantic.busy.chat",
            "semantic.cancelDownload",
            "semantic.endSearch",
            "semantic.prepareSearch"
        ] {
            _ = try await call(action, false)
        }
        let query = FeatureFileQuery(
            text: "fixture",
            limit: 24,
            fuzzy: true,
            type: .all,
            order: .relevance,
            now: Date()
        )
        #expect(try await JSONDecoder().decode([AskFileHit].self, from: call("files.search", query)).isEmpty)
        let recent = FeatureFileQuery(text: nil, limit: 24, fuzzy: false, type: .all, order: .recent, now: Date())
        #expect(try await JSONDecoder().decode([AskFileHit].self, from: call("files.search", recent)).isEmpty)
        _ = try await runtime.handle(.init(
            destination: .background,
            action: "files.open",
            payload: Data("/fixture".utf8)
        ))
        #expect(names.usage["/fixture"] == 1)
        _ = try await runtime.handle(.init(
            destination: .background,
            action: "files.forget",
            payload: Data("/fixture".utf8)
        ))
        #expect(try await JSONDecoder().decode(
            [AskFileHit].self,
            from: call("semantic.search", FeatureSemanticQuery(text: "fixture search", type: .all, limit: 24))
        ).isEmpty)
        #expect(try await JSONDecoder().decode(Bool.self, from: call("semantic.enabled", true)) == false)
        #expect(try await JSONDecoder().decode(
            SemanticFileStore.ProcessingPage?.self,
            from: call("semantic.page", FeatureProcessingPage(section: .pending, offset: -1, limit: 1000))
        ) == nil)
        await #expect(throws: FeatureRPC.Failure.invalidMessage) {
            try await call(
                "files.search",
                FeatureFileQuery(text: nil, limit: 101, fuzzy: true, type: .all, order: .recent, now: Date())
            )
        }
        await #expect(throws: FeatureRPC.Failure.invalidMessage) { try await call("invalid", false) }
        let snapshot = content.backgroundSnapshot()
        let proxy = SemanticFileSearchService(settings: settings, supported: false, automaticStart: false, remote: true)
        proxy.applyRemoteSnapshot(snapshot)
        #expect(proxy.phase == snapshot.phase && !proxy.isEnabled)
        #expect(try JSONDecoder().decode(FeatureSemanticSnapshot.self, from: JSONEncoder().encode(snapshot))
            .files == snapshot.files)
        let cache = FeatureIndexStatusCache()
        #expect(!cache.update(.init()))
        #expect(cache.update(.init(phase: .ready, count: 10)))
        #expect(cache.value.count == 10)
        _ = try await call("shutdown", false)
    }
}

extension FeatureBackgroundRuntimeTests {
    @Test func servicePublishesHealthAndIndexStateAndStopsItsObserversWithoutAppStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "feature-service-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        let previous = FeatureProcess.handle
        defer {
            FeatureProcess.handle = previous
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let names = AskFileIndex(configuration: { (false, .init()) }, snapshotURL: root.appendingPathComponent("index.bin"), defaults: defaults)
        let content = SemanticFileSearchService(settings: SettingsStore(defaults: defaults), directory: root, supported: false, automaticStart: false)
        var publications: [FeatureCommand] = []
        let runtime = FeatureBackgroundRuntime(names: names, content: content, healthDirectory: root.appendingPathComponent("health"), publish: { publications.append($0) })
        runtime.start()
        for _ in 0..<100 where !publications.contains(where: { $0.action == "indexSnapshot" }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(publications.contains { $0.action == "status" })
        #expect(publications.contains { $0.action == "indexSnapshot" })
        let command = FeatureCommand(destination: .background, action: "shutdown")
        _ = try await runtime.handle(command)
        let count = publications.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(publications.count == count)
    }
}


extension FeatureBackgroundRuntimeTests {
    @Test func staleActivityCannotResumeOrPermanentlyPauseIndexing() async throws {
        let domain = "feature-priority-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults)
        let names = AskFileIndex(configuration: { (false, .init()) }, defaults: defaults)
        let content = SemanticFileSearchService(settings: settings, supported: false, automaticStart: false)
        let runtime = FeatureBackgroundRuntime(names: names, content: content)
        func activity(_ source: String, _ busy: Bool, _ uptime: TimeInterval) async throws {
            _ = try await runtime.handle(.init(destination: .background, action: "semantic.busy." + source,
                payload: JSONEncoder().encode(FeatureForegroundActivity(busy: busy, uptime: uptime))))
        }
        try await activity("voiceEditor", true, 20)
        try await activity("voice", false, 25)
        #expect(runtime.isForegroundBusy)
        try await activity("voiceEditor", false, 19)
        #expect(runtime.isForegroundBusy)
        try await activity("voiceEditor", false, 30)
        #expect(!runtime.isForegroundBusy)
        try await activity("voiceEditor", true, 21)
        #expect(!runtime.isForegroundBusy)
        _ = try await runtime.handle(.init(destination: .background, action: "shutdown"))
    }
}
