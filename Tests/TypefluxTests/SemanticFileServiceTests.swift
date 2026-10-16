import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

final class SemanticFixtureModels: SemanticModelHandling, @unchecked Sendable {
    let fetchStarted = AskSearchCancellation()
    var failure = false
    var status = 200
    var delay: Duration = .zero
    let source: URL
    init(source: URL) {
        self.source = source
    }

    func verify(_: URL, cancelled: @Sendable () -> Bool) throws {
        if cancelled() {
            throw CancellationError()
        }
        if failure {
            throw SemanticFileStore.Failure.invalidVector
        }
    }

    func install(_ url: URL, to target: URL, cancelled: @Sendable () -> Bool) throws {
        try verify(url, cancelled: cancelled)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: url, to: target)
    }

    func fetch(progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, URLResponse) {
        fetchStarted.cancel()
        progress(100)
        try await Task.sleep(for: delay)
        let copy = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: copy)
        return (copy, HTTPURLResponse(url: SemanticModel.url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class SemanticFixtureQuery: SemanticQueryEmbedding, @unchecked Sendable {
    func query(_: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        if lifecycle.isCancelled {
            throw CancellationError()
        }
        return semanticVector()
    }

    func stop() {}
}

final class SemanticFixtureWatcher: AskFileWatching {
    var started: [String] = []
    var change: (([AskFileChange], UInt64) -> Void)?
    func start(paths: [String], since _: UInt64?, onChange: @escaping ([AskFileChange], UInt64) -> Void) {
        started = paths; change = onChange
    }

    func stop() {
        started = []; change = nil
    }
}

@Suite("Semantic service lifecycle", .serialized, .exclusiveUIState)
@MainActor
struct SemanticFileServiceTests {
    func fixture(supported: Bool = true) throws
        -> (SemanticFileSearchService, URL, SemanticFixtureReader, SemanticFixtureModels) {
        let root = try semanticFixture(), suite = "semantic-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(defaults: defaults)
        // Tests never use standard defaults, watched home folders, network or a real model.
        var names = AskLauncherSearchSettings(); names.fileRoots = [root.path]; names.excludedPaths = []
        settings.askLauncherSearchSettings = names
        let source = root.appendingPathComponent("fixture-model"); try Data("model".utf8).write(to: source)
        let reader = SemanticFixtureReader(path: root.path + "/handbook.txt"),
            models = SemanticFixtureModels(source: source)
        let service = SemanticFileSearchService(
            settings: settings,
            directory: root,
            helper: URL(fileURLWithPath: "/usr/bin/true"),
            supported: supported,
            watcher: SemanticFixtureWatcher(),
            access: { true },
            automaticStart: false,
            lowPowerMode: { false },
            thermalConstrained: { false },
            models: models,
            makeReader: { reader },
            makeEncoder: { _, _ in SemanticFixtureEncoder() },
            makeQuery: { _, _ in SemanticFixtureQuery() }
        )
        defaults.removePersistentDomain(forName: suite)
        settings.askLauncherSearchSettings = names
        return (service, root, reader, models)
    }

    static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func `default off and unsupported cannot be enabled`() async throws {
        let (service, root, _, _) = try fixture(supported: false)
        defer { try? FileManager.default.removeItem(at: root) }
        service.start()
        #expect(service.phase == .off); #expect(!service.setEnabled(true))
        #expect(!service.preferences.enabled)
        #expect(await service.search("query", type: .all, limit: 10).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("semantic-files.sqlite").path))
        #expect(!service.setEnabled(true))
        service.settings.semanticFileSearch = .init(enabled: true)
        service.start(force: true)
        #expect(service.phase == .off, "persisted preferences cannot bypass the hardware gate")
        await service.clear()
    }

    @Test func `model download retry search rebuild and removal`() async throws {
        let (service, root, reader, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var names = service.settings.askLauncherSearchSettings
        names.fileRoots = []
        service.settings.askLauncherSearchSettings = names
        #expect(!service.setEnabled(true))
        names.fileRoots = [root.path]
        service.settings.askLauncherSearchSettings = names
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .modelRequired }
        models.status = 503
        service.downloadModel()
        try await Self.wait { service.phase == .failed }
        models.status = 200
        service.downloadModel()
        try await Self.wait { service.phase == .ready }
        #expect(service.files == 1); #expect(service.chunks == 1); #expect(service.modelReady)
        #expect(service.indexedCounts.files == 1 && service.indexedCounts.documents == 1)
        let hits = await service.search("报销流程", type: .all, limit: 10)
        #expect(hits.map(\.path) == [reader.path]); #expect(hits.first?.evidence != nil)
        reader.failed = true
        #expect(await service.search("reimbursement", type: .all, limit: 10).isEmpty)
        reader.failed = false
        #expect(await service.search("", type: .all, limit: 10).isEmpty)
        service.settings.askQuickFileSearchEnabled = false
        #expect(!service.setEnabled(true))
        #expect(await service.search("query", type: .all, limit: 10).isEmpty)
        service.settings.askQuickFileSearchEnabled = true
        service.pause(true)
        try await Self.wait { service.phase == .paused }
        #expect(service.files == 1)
        #expect(service.isEnabled)
        #expect(await service.search("报销流程", type: .all, limit: 10).map(\.path) == [reader.path])
        service.pause(false)
        try await Self.wait { service.phase == .ready }
        #expect(service.isEnabled)
        service.setForegroundBusy(true)
        try await Self.wait { service.phase == .paused }
        service.setForegroundBusy(false)
        try await Self.wait { service.phase == .ready }
        await service.rebuild()
        try await Self.wait { service.phase == .ready }
        await service.clear()
        #expect(service.phase == .off); #expect(service.files == 0)
        #expect(service.indexedCounts == .init())
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        await service.clear(removeModel: true)
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path)); #expect(!service.modelReady)
    }

    @Test func `download cancellation corruption and disabling`() async throws {
        let (service, root, _, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .modelRequired }
        models.delay = .seconds(1)
        service.downloadModel(); service.cancelDownload()
        try await Self.wait { service.phase == .modelRequired }
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path))
        models.delay = .zero; models.failure = true
        service.downloadModel()
        try await Self.wait { service.phase == .failed }
        #expect(!service.modelReady)
        service.setEnabled(false)
        #expect(service.phase == .off); #expect(!service.preferences.enabled)
        await service.clear()
        #expect(throws: (any Error).self) { try SemanticModel.verify(models.source) }
        #expect(throws: CancellationError.self) { try SemanticModel.verify(models.source, cancelled: { true }) }
    }

    @Test func `automatic settings watcher and power changes keep lifecycle coherent`() async throws {
        let (fixture, root, reader, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: fixture.modelURL)
        let watcher = SemanticFixtureWatcher(), encoder = SemanticFixtureEncoder()
        let constrained = AskSearchCancellation(), overheated = AskSearchCancellation()
        let updated = AskSearchCancellation()
        let service = SemanticFileSearchService(settings: fixture.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: watcher,
                                                access: { true }, lowPowerMode: { constrained.isCancelled },
                                                thermalConstrained: { overheated.isCancelled }, models: models,
                                                makeReader: { reader }, makeEncoder: { _, _ in encoder },
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        fixture.settings.semanticFileSearch = .init(enabled: true)
        try await Self.wait { service.phase == .ready }
        #expect(watcher.started == [root.path])
        reader.modified = reader.modified.addingTimeInterval(1)
        encoder.after = { updated.cancel() }
        watcher.change?([.init(path: reader.path, rescan: false)], 1)
        try await Self.wait { updated.isCancelled }
        try await Self.wait { service.phase == .ready }
        constrained.cancel()
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: ProcessInfo.processInfo)
        #expect(service.phase == .ready, "Low Power Mode uses the slower work budget")
        #expect(service.isEnabled)
        #expect(await service.search("报销流程", type: .all, limit: 10).map(\.path) == [reader.path])
        let calls = encoder.calls
        reader.modified = reader.modified.addingTimeInterval(1)
        watcher.change?([.init(path: reader.path, rescan: false)], 2)
        try await Task.sleep(for: .milliseconds(2250))
        #expect(encoder.calls > calls, "Low Power Mode still makes useful checkpointed progress")
        overheated.cancel()
        NotificationCenter.default.post(
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: ProcessInfo.processInfo
        )
        try await Self.wait { service.phase == .paused }
        #expect(service.isEnabled, "thermal pressure preserves lexical content search")
        fixture.settings.semanticFileSearch = .init(enabled: false)
        try await Self.wait { service.phase == .off }
        #expect(watcher.started.isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func `irrelevant events do not rescan and changed files use targeted reconciliation`() async throws {
        let (original, root, reader, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: original.modelURL)
        var names = original.settings.askLauncherSearchSettings
        names.excludedPaths = [root.path + "/Library"]
        original.settings.askLauncherSearchSettings = names
        let watcher = SemanticFixtureWatcher(), encoder = SemanticFixtureEncoder()
        let service = SemanticFileSearchService(settings: original.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: watcher,
                                                access: { true }, lowPowerMode: { false },
                                                thermalConstrained: { false },
                                                models: models,
                                                makeReader: { reader }, makeEncoder: { _, _ in encoder },
                                                makeQuery: { _, _ in SemanticFixtureQuery() })
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .ready }
        let initialCrawls = reader.directoryReads
        #expect(encoder.calls == 1)
        service.setForegroundBusy(true)
        #expect(service.phase == .paused)
        service.setForegroundBusy(false)
        #expect(service.phase == .ready && reader.directoryReads == initialCrawls)
        watcher.change?([
            .init(path: root.path + "/semantic-files.sqlite-wal", rescan: false, isDirectory: false),
            .init(path: root.path + "/Library/ignored.md", rescan: false, isDirectory: false),
            .init(path: root.path + "/unrelated.json", rescan: false, isDirectory: false)
        ], 1)
        try await Task.sleep(for: .milliseconds(2250))
        #expect(service.phase == .ready && reader.directoryReads == initialCrawls)
        reader.modified = reader.modified.addingTimeInterval(1)
        watcher.change?([.init(path: reader.path, rescan: false, isDirectory: false)], 2)
        try await Self.wait { encoder.calls == 2 && service.phase == .ready }
        #expect(reader.directoryReads == initialCrawls)
        await service.clear(removeModel: true)
    }

    @Test func `corrupt index can be cleared without removing verified model`() async throws {
        let (service, root, _, models) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: models.source, to: service.modelURL)
        let index = root.appendingPathComponent("semantic-files.sqlite")
        try Data("corrupt index".utf8).write(to: index)
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .failed }
        #expect(service.modelReady)
        await service.clear()
        #expect(!FileManager.default.fileExists(atPath: index.path))
        #expect(FileManager.default.fileExists(atPath: service.modelURL.path))
        #expect(service.setEnabled(true))
        try await Self.wait { service.phase == .ready }
        await service.clear(removeModel: true)
    }

    @Test func `download failures and early cancellation release session`() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SemanticFailureURLProtocol.self]
        let downloader = try SemanticModelDownload(
            url: #require(URL(string: "https://semantic.test/model")),
            configuration: config,
            progress: { _ in }
        )
        await #expect(throws: (any Error).self) { try await downloader.fetch() }
        await #expect(throws: (any Error).self) { try await downloader.fetch() }
        let cancelled = try SemanticModelDownload(
            url: #require(URL(string: "https://semantic.test/model")),
            configuration: config,
            progress: { _ in }
        )
        let task = Task { try await cancelled.fetch() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func `live model download when explicitly requested`() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_LIVE_DOWNLOAD"] == "1" else { return }
        let progress = AskSearchCancellation()
        let (temporary, response) = try await SemanticModelFiles().fetch { received in
            if received > 0, received < SemanticModel.bytes {
                progress.cancel()
            }
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(progress.isCancelled, "the real downloader must report progress")
        try await Task.detached { try SemanticModel.verify(temporary) }.value
    }

    @Test func `actual model checksum and atomic install when provided`() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] else { return }
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("model.gguf"), source = URL(fileURLWithPath: path)
        try await Task.detached {
            try SemanticModel.verify(source)
            try SemanticModel.install(source, to: target, cancelled: { false })
            try SemanticModel.verify(target)
        }.value
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(throws: CancellationError.self) { try SemanticModel.install(source, to: target, cancelled: { true }) }
    }

    /// Like `SettingsBehaviorTestSupport.wait`, but reports the step that never became ready.
    static func ready(sourceLocation: SourceLocation = #_sourceLocation,
                      _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("UI state did not become ready within three seconds", sourceLocation: sourceLocation)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func `native controls use inline setup and management`() async throws {
        typealias Support = SettingsBehaviorTestSupport
        let (unsupported, unsupportedRoot, _, _) = try fixture(supported: false)
        let (service, root, _, _) = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unsupportedRoot)
        }
        try await Support.withFixture { _ in
            try await Support.withWindow(SemanticFileSearchSettingsView(service: unsupported, filesEnabled: true),
                                         width: 760, height: 300) { _, host in
                let toggle = try #require(Support.elements(in: host).first {
                    $0.value("accessibilityIdentifier") as? String == "semantic.enabled"
                })
                #expect(toggle.value("isAccessibilityEnabled") as? Bool == false)
                #expect(Support.contains(L("semantic.unsupported"), in: host))
            }
            let view = SemanticFileSearchSettingsView(service: service, filesEnabled: true)
            try await Support.withWindow(view, width: 760, height: 560) { window, host in
                #expect(Support.contains(L("semantic.index.setup.download"), in: host))
                #expect(Support.contains(L("semantic.enable.download"), in: host))
                #expect(window.attachedSheet == nil)
                try Support.button(L("semantic.enable.download"), in: host).press()
                try await Self.ready { service.phase == .ready }
                #expect(window.attachedSheet == nil)
                #expect(service.settings.askLauncherSearchSettings.fileRoots == [root.path])
                #expect(Support.contains(L("semantic.metric.index"), in: host))
                for key in ["semantic.metric.files", "semantic.metric.documents", "semantic.metric.images",
                            "semantic.metric.audio", "semantic.metric.videos"] {
                    #expect(Support.contains(L(key), in: host))
                }

                service.pause(true)
                try await Self.ready { service.phase == .paused }
                try await Self.ready { Support.contains(L("semantic.resume"), in: host) }
                try Support.button(L("semantic.resume"), in: host).press()
                try await Self.ready { service.phase == .ready }

                var phases: [SemanticFileSearchService.Phase] = []
                let watch = service.$phase.sink { phases.append($0) }
                defer { watch.cancel() }
                try await Self.ready { Support.contains(L("semantic.rebuild"), in: host) }
                try Support.button(L("semantic.rebuild"), in: host).press()
                try await Self.ready {
                    phases.contains(.off) && service.phase == .ready && service.files == 1
                        && service.preferences.enabled
                }
                #expect(window.attachedSheet == nil)
            }
        }
        await service.clear(removeModel: true)
    }

    @Test func `folders edited during rebuild are not restored`() async throws {
        let (service, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        await service.prepareModelIfNeeded()
        try await Self.wait { service.phase == .ready }
        let rebuild = Task { await service.rebuild() }
        // Act while the rebuild is clearing: it has switched the feature off but not restarted it.
        var spins = 0
        while service.settings.semanticFileSearch.enabled, spins < 100_000 {
            await Task.yield(); spins += 1
        }
        var names = service.settings.askLauncherSearchSettings
        names.fileRoots = []
        service.settings.askLauncherSearchSettings = names
        await rebuild.value
        #expect(!service.settings.semanticFileSearch.enabled && service.settings.askLauncherSearchSettings.fileRoots
            .isEmpty)
        #expect(service.phase == .off)
        await service.clear(removeModel: true)
    }

    @Test func `native management confirms clearing and model removal inline`() async throws {
        typealias Support = SettingsBehaviorTestSupport
        let (service, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(service.setEnabled(true))
        await service.prepareModelIfNeeded()
        try await Self.wait { service.phase == .ready }
        let stored = service.storage()
        #expect(stored.index > 0 && stored.model > 0)
        try await Support.withFixture { _ in
            let view = SemanticFileSearchSettingsView(service: service, filesEnabled: true)
            try await Support.withWindow(view, width: 760, height: 620) { window, host in
                for (key, confirm) in [("semantic.clear", "semantic.clear.confirm"),
                                       ("semantic.remove", "semantic.remove.confirm")] {
                    try await Self.ready { Support.contains(L(key), in: host) }
                    try Support.button(L(key), in: host).press()
                    let message = key == "semantic.clear" ? "semantic.clear.message" : "semantic.remove.message"
                    try await Self.ready { Support.contains(L(message), in: host) }
                    #expect(window.attachedSheet == nil)
                    try Support.button(L(confirm), in: host).press()
                    try await Self.ready {
                        !service.preferences.enabled && service.phase == .off &&
                            service.modelReady == (key == "semantic.clear")
                    }
                    #expect(service.settings.askLauncherSearchSettings.fileRoots == [root.path])
                    if key == "semantic.clear" {
                        try Support.button(L("semantic.enable"), in: host).press()
                        try await Self.ready { service.phase == .ready }
                    }
                }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: service.modelURL.path))
        #expect(service.storage().index == 0 && service.storage().model == 0)
    }
}
