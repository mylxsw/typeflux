import Foundation
import Testing
@testable import Typeflux

final class SemanticQueryProbe: SemanticQueryEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var preparations = 0
    private var failures: Int
    let delay: Duration
    var calls: Int {
        lock.withLock { count }
    }

    var warmed: Int {
        lock.withLock { preparations }
    }

    init(failures: Int = 0, delay: Duration = .zero) {
        self.failures = failures; self.delay = delay
    }

    func prepare(lifecycle _: AskSearchCancellation) async throws {
        lock.withLock { preparations += 1 }
    }

    func query(_: String, lifecycle: AskSearchCancellation) async throws -> [Float] {
        let fail = lock.withLock { count += 1; let fail = failures > 0; failures -= 1; return fail }
        try await Task.sleep(for: delay)
        if lifecycle.isCancelled {
            throw CancellationError()
        }
        if fail {
            throw AskFileReadError.timeout
        }
        return semanticVector()
    }

    func stop() {}
}

private final class SemanticPipelineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var events: [String] { lock.withLock { messages } }
    func record(_ event: String) { lock.withLock { messages.append(event) } }
}

private final class SemanticObservedReader: AskFileReading {
    let reader = AskFileReader(), log: SemanticPipelineLog
    init(log: SemanticPipelineLog) { self.log = log }
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        log.record("read-" + request.operation.rawValue + "-start")
        defer { log.record("read-" + request.operation.rawValue + "-end") }
        return try reader.read(request, isCancelled: isCancelled)
    }
    func stream(_ request: AskFileReadRequest, isCancelled: () -> Bool,
                receive: (AskFileReadResponse) -> Bool) throws {
        log.record("stream-" + request.operation.rawValue + "-start")
        defer { log.record("stream-" + request.operation.rawValue + "-end") }
        try reader.stream(request, isCancelled: isCancelled, receive: receive)
    }
}

private final class SemanticObservedEncoder: SemanticEmbedding {
    let worker: SemanticEmbeddingWorker, log: SemanticPipelineLog
    init(helper: URL, model: URL, log: SemanticPipelineLog) {
        self.log = log; worker = SemanticEmbeddingWorker(helper: helper, model: model, indexing: true)
    }
    func embed(_ texts: [String], cancelled: () -> Bool) throws -> [[Float]] {
        log.record("encode-start")
        defer { log.record("encode-end") }
        return try worker.embed(texts, cancelled: cancelled)
    }
    func release() { worker.release() }
}

@Suite("Realtime content search and recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticRealtimeSearchTests {
    func fixture(query: SemanticQueryProbe = .init(), thermal: AskSearchCancellation = .init(),
                 access: AskSearchCancellation = .init(), text: String? = nil) async throws
        -> (SemanticFileSearchService, URL, SemanticFixtureReader, SemanticFixtureWatcher) {
        let (base, root, reader, models) = try SemanticFileServiceTests().fixture()
        if let text {
            reader.text = text
        }
        try FileManager.default.copyItem(at: models.source, to: base.modelURL)
        let watcher = SemanticFixtureWatcher()
        let service = SemanticFileSearchService(settings: base.settings, directory: root,
                                                helper: URL(fileURLWithPath: "/usr/bin/true"), supported: true,
                                                watcher: watcher,
                                                access: { !access.isCancelled }, automaticStart: false,
                                                lowPowerMode: { false },
                                                thermalConstrained: { thermal.isCancelled }, models: models,
                                                makeReader: { reader },
                                                makeEncoder: { _, _ in SemanticFixtureEncoder() },
                                                makeQuery: { _, _ in query })
        #expect(service.setEnabled(true))
        try await SemanticFileServiceTests.wait { service.phase == .ready }
        return (service, root, reader, watcher)
    }

    @Test func `lexical publishes before slow model and timeout does not disable next query`() async throws {
        let query = SemanticQueryProbe(failures: 1, delay: .milliseconds(180))
        let (service, root, reader, _) = try await fixture(query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        var partial: [AskFileHit] = [], callsAtPublication: Int?
        let task = Task { await service.search("reimbursement", type: .all, limit: 10) {
            partial = $0; callsAtPublication = query.calls
        } }
        try await SemanticFileServiceTests.wait { !partial.isEmpty }
        #expect(partial.map(\.path) == [reader.path])
        #expect(callsAtPublication == 0, "FTS publication precedes semantic scheduling")
        #expect(await task.value.map(\.path) == [reader.path])
        #expect(service.queryState == .degraded && service.phase == .ready && service.isEnabled)
        #expect(await service.search("报销流程", type: .all, limit: 10).map(\.path) == [reader.path])
        #expect(query.calls == 2 && service.queryState == .idle)
        await service.clear(removeModel: true)
    }

    @Test func `pause keeps searching and voice or thermal pressure keeps only lexical`() async throws {
        let query = SemanticQueryProbe(), thermal = AskSearchCancellation()
        let (service, root, reader, _) = try await fixture(query: query, thermal: thermal)
        defer { try? FileManager.default.removeItem(at: root) }
        service.prepareForSearch()
        try await SemanticFileServiceTests.wait { query.warmed == 1 && service.queryState == .idle }
        service.pause(true)
        #expect(service.phase == .paused && service.isEnabled)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        #expect(query.calls == 1)
        service.setForegroundBusy(true)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        service.prepareForSearch()
        #expect(query.calls == 1 && query.warmed == 1)
        service.setForegroundBusy(false)
        thermal.cancel()
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        #expect(query.calls == 1)
        #expect(await service.search("reimbursement", type: .folder, limit: 5).isEmpty)
        #expect(await service.search("reimbursement", type: .all, limit: 0).isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func `both entrypoints publish lexical while semantic is pending and keep selection`() async throws {
        let query = SemanticQueryProbe(delay: .milliseconds(250))
        let (service, root, reader, _) = try await fixture(query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AskTestFileIndex(), session = AskQuickSearchSession()
        session.update(text: "reimbursement", chinese: false, calculator: false,
                       sources: .init(files: files, semantic: service))
        try await SemanticFileServiceTests.wait { session.results?.files.first?.path == reader.path }
        #expect(session.isSearching && session.results?.searchingContent == true)
        #expect(session.results?.best == nil)
        let row = try #require(session.results?.rows.firstIndex { session.results?.file(at: $0)?.path == reader.path })
        session.results?.highlight(row)
        try await SemanticFileServiceTests.wait { !session.isSearching }
        #expect(try session.results?.file(at: #require(session.results?.highlightedRow))?.path == reader.path)
        session.update(text: "reimbursement", chinese: false, calculator: false,
                       sources: .init(files: files, semantic: service))
        session.setVisible(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.results == nil)
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { service })
        let request = AskPluginRequest(text: "reimbursement", origin: .argument,
                                       keyword: AskFileSearchPlugin.keywords[0], options: [:],
                                       interfaceLanguage: .english)
        var partials: [AskPluginOutput] = []
        let output = try await plugin.run(request, plan: plugin.plan(request), progress: { partials.append($0) })
        #expect(partials.contains { $0.items.contains { $0.fileHit?.path == reader.path } })
        #expect(output.items.contains { $0.fileHit?.path == reader.path })
        session.cancel()
        await service.clear(removeModel: true)
    }

    @Test func `semantic keyword publishes lexical while encoding is pending and keeps safe file selection`() async throws {
        let query = SemanticQueryProbe(delay: .milliseconds(250))
        let (service, root, reader, _) = try await fixture(query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = AskSemanticFileSearchPlugin(semantic: { service }, settings: { .init() })
        let keyword = AskSemanticFileSearchPlugin.keywords[0]
        let session = AskPluginSession(plugins: [plugin], keywords: { [keyword] })
        session.enter(keyword)
        session.update(text: "reimbursement", selection: nil, language: .english)
        try await SemanticFileServiceTests.wait { session.partial?.items.contains { $0.fileHit?.path == reader.path } == true }
        #expect(session.isRunning)
        let row = try #require(session.partial?.items.firstIndex { $0.fileHit?.path == reader.path })
        #expect(session.selectItem(row))
        #expect(session.currentOutput?.action(for: .enter)?.kind == .open(URL(fileURLWithPath: reader.path)))
        try await SemanticFileServiceTests.wait { session.output != nil }
        #expect(session.output?.selected?.fileHit?.path == reader.path)
        session.update(text: "reimbursement revised", selection: nil, language: .english)
        session.deactivate()
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.currentOutput == nil)
        await service.clear(removeModel: true)
    }

    @Test func `permission withdrawal revalidates early hits and preserves permitted files`() async throws {
        let access = AskSearchCancellation(), query = SemanticQueryProbe(delay: .milliseconds(100))
        let (service, root, reader, _) = try await fixture(query: query, access: access)
        defer { try? FileManager.default.removeItem(at: root) }
        var early: [AskFileHit] = []
        let final = await service.search("reimbursement", type: .all, limit: 5) {
            early = $0
            // Simulate the metadata helper losing permission after the first verified publication.
            reader.failed = true
            access.cancel()
        }
        #expect(early.map(\.path) == [reader.path] && final.isEmpty)
        #expect(service.phase == .ready && service.isEnabled)
        reader.failed = false
        // Temporary fixture files remain allowed without Full Disk Access; no protected user file is read.
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        await service.clear(removeModel: true)
    }

    @Test func `scope change clear and cancellation reject late results`() async throws {
        let query = SemanticQueryProbe(delay: .milliseconds(200))
        let (service, root, _, _) = try await fixture(query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        var progress = false
        let task = Task { await service.search("reimbursement", type: .all, limit: 5) { _ in progress = true } }
        try await SemanticFileServiceTests.wait { progress }
        var scope = service.settings.askLauncherSearchSettings
        scope.fileRoots = []
        service.settings.askLauncherSearchSettings = scope
        #expect(await task.value.isEmpty)
        #expect(!service.isEnabled)
        #expect(await service.search("reimbursement", type: .all, limit: 5).isEmpty)
        await service.clear(removeModel: true)
    }

    @Test func `existing lexical index works without model or helper`() async throws {
        let (service, root, reader, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        service.setEnabled(false)
        try FileManager.default.removeItem(at: service.modelURL)
        service.setEnabled(true)
        try await SemanticFileServiceTests.wait { service.phase == .modelRequired }
        #expect(service.isEnabled && !service.modelReady)
        #expect(await service.search("reimbursement", type: .all, limit: 5).map(\.path) == [reader.path])
        await service.clear()
    }

    @Test(arguments: [false, true])
    func `real file change indexes and publishes with real model when provided`(observed: Bool) async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_TEST_MODEL"] else { return }
        let (base, root, _, _) = try SemanticFileServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: URL(fileURLWithPath: modelPath), to: base.modelURL)
        let initial = root.appendingPathComponent("guide.txt"), added = root.appendingPathComponent("new-document.txt")
        try "Employees attach receipts for reimbursement.".write(to: initial, atomically: true, encoding: .utf8)
        let watcher = SemanticFixtureWatcher(), log = SemanticPipelineLog()
        let service: SemanticFileSearchService
        if observed {
            service = SemanticFileSearchService(settings: base.settings, directory: root, supported: true,
                watcher: watcher, access: { true }, automaticStart: false,
                lowPowerMode: { false }, thermalConstrained: { false },
                makeReader: { SemanticObservedReader(log: log) },
                makeEncoder: { SemanticObservedEncoder(helper: $0, model: $1, log: log) })
        } else {
            service = SemanticFileSearchService(settings: base.settings, directory: root, supported: true,
                watcher: watcher, access: { true }, automaticStart: false,
                lowPowerMode: { false }, thermalConstrained: { false })
        }
        #expect(service.setEnabled(true))
        let deadline = ContinuousClock.now + .seconds(30)
        while service.phase != .ready, service.phase != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        print("Real index diagnostic: phase=\(service.phase), modelReady=\(service.modelReady), files=\(service.files), skipped=\(service.skipped)")
        print("Real pipeline events: \(log.events.joined(separator: ","))")
        try #require(service.phase == .ready)
        #expect(service.files == 1)
        try "New reimbursement policy REFERENCE-4829 requires attached receipts.".write(
            to: added,
            atomically: true,
            encoding: .utf8
        )
        watcher.change?([.init(path: added.path, rescan: false, isDirectory: false)], 1)
        try await SemanticFileServiceTests.wait { service.phase == .ready && service.files == 2 }
        let session = AskQuickSearchSession()
        session.update(text: "REFERENCE-4829", chinese: false, calculator: false,
                       sources: .init(files: AskTestFileIndex(), semantic: service))
        try await SemanticFileServiceTests.wait { !session.isSearching }
        #expect(session.results?.files.contains { $0.path == added.path } == true)
        #expect(session.results?.files.first { $0.path == added.path }?.evidence?.text
            .contains("REFERENCE-4829") == true)
        session.cancel()
        await service.clear(removeModel: true)
    }
    @Test func fileModeLexicalDoesNotWaitForASlowFilenameProvider() async throws {
        let query = SemanticQueryProbe(delay: .milliseconds(250))
        let (service, root, reader, _) = try await fixture(query: query)
        defer { try? FileManager.default.removeItem(at: root) }
        let namesStarted = AskSearchCancellation(), releaseNames = AskSearchCancellation()
        let files = AskControlledSearchIndex()
        files.fileSearch = { _ in
            namesStarted.cancel()
            while !releaseNames.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return []
        }
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { service })
        let request = AskPluginRequest(text: "reimbursement", origin: .argument,
                                      keyword: AskFileSearchPlugin.keywords[0], options: [:], interfaceLanguage: .english)
        var lexical = false
        let run = Task {
            try await plugin.run(request, plan: plugin.plan(request), progress: { output in
                if output.items.contains(where: { $0.fileHit?.path == reader.path }) { lexical = true }
            })
        }
        defer { releaseNames.cancel(); run.cancel() }
        try await SemanticFileServiceTests.wait { namesStarted.isCancelled && lexical }
        releaseNames.cancel()
        #expect(try await run.value.items.contains { $0.fileHit?.path == reader.path })
        await service.clear(removeModel: true)
    }

}
