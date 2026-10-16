import Foundation
import Testing
@testable import Typeflux

private final class SemanticMetadataRecoveryControl: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var blockRecovery = false
    private var attempts = 0
    private var afterStall: (@Sendable () -> Void)?
    var reads: Int {
        lock.withLock { attempts }
    }

    func arm(blockRecovery: Bool = false, afterStall: (@Sendable () -> Void)? = nil) {
        lock.withLock {
            armed = true; attempts = 0; self.blockRecovery = blockRecovery
            self.afterStall = afterStall
        }
    }

    func intercept(_ request: AskFileReadRequest, cancelled: () -> Bool) throws {
        guard request.operation == .content, request.readText == false else { return }
        let state = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            guard armed else { return (false, nil) }
            attempts += 1
            return (attempts == 1 || blockRecovery, afterStall)
        }
        guard state.0 else { return }
        while !cancelled() {
            Thread.sleep(forTimeInterval: 0.001)
        }
        state.1?()
        throw AskFileReadError.cancelled
    }
}

private final class SemanticRecoveringReader: AskFileReading {
    let reader: SemanticFixtureReader, control: SemanticMetadataRecoveryControl
    init(reader: SemanticFixtureReader, control: SemanticMetadataRecoveryControl) {
        self.reader = reader; self.control = control
    }

    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        try control.intercept(request, cancelled: isCancelled)
        return try reader.read(request, isCancelled: isCancelled)
    }
}

@Suite("Semantic metadata timeout recovery", .serialized, .exclusiveUIState)
@MainActor
struct SemanticMetadataRecoveryTests {
    @Test func `both entries recover an empty warm metadata timeout within the same query`() async throws {
        let control = SemanticMetadataRecoveryControl(), query = SemanticQueryProbe()
        let (service, root, reader, _) = try await SemanticRealtimeSearchTests().fixture(query: query, makeReader: {
            SemanticRecoveringReader(reader: $0, control: control)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        service.pause(true); service.prepareForSearch()
        try await SemanticFileServiceTests.wait { service.queryState == .idle && query.warmed == 1 }
        let files = AskTestFileIndex(), session = AskQuickSearchSession()
        control.arm()
        session.update(text: "如何取回差旅垫付费用", chinese: false, calculator: false,
                       sources: .init(files: files, semantic: service))
        try await SemanticFileServiceTests
            .wait { !session.isSearching && session.results?.files.first?.path == reader.path }
        #expect(service.queryState == .idle && control.reads >= 2 && query.calls == 1)
        session.cancel()
        control.arm()
        let plugin = AskFileSearchPlugin(index: { files }, settings: { .init() }, semantic: { service })
        let request = AskPluginRequest(text: "如何取回差旅垫付费用", origin: .argument,
                                       keyword: AskFileSearchPlugin.keywords[0], options: [:],
                                       interfaceLanguage: .english)
        let output = try await plugin.run(request, plan: plugin.plan(request), progress: { _ in })
        #expect(output.items.contains { $0.fileHit?.path == reader.path })
        #expect(service.queryState == .idle && control.reads >= 2 && query.calls == 2)
        await service.clear(removeModel: true)
    }

    @Test func `metadata recovery still rejects withdrawn permissions and cancels a stalled retry`() async throws {
        let control = SemanticMetadataRecoveryControl(), query = SemanticQueryProbe()
        let (service, root, reader, _) = try await SemanticRealtimeSearchTests().fixture(query: query, makeReader: {
            SemanticRecoveringReader(reader: $0, control: control)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        service.pause(true); service.prepareForSearch()
        try await SemanticFileServiceTests.wait { service.queryState == .idle && query.warmed == 1 }
        control.arm(afterStall: { reader.failed = true })
        #expect(await service.search("如何取回差旅垫付费用", type: .all, limit: 5).isEmpty)
        #expect(control.reads >= 2)
        reader.failed = false
        control.arm(blockRecovery: true)
        let task = Task { await service.search("如何取回差旅垫付费用", type: .all, limit: 5) }
        try await SemanticFileServiceTests.wait { control.reads == 2 }
        task.cancel()
        #expect(await task.value.isEmpty)
        #expect(control.reads == 2, "cancellation cannot start a third validation attempt")
        await service.clear(removeModel: true)
    }

    @Test func `a stalled pure semantic recovery fails closed without another metadata or model attempt`() async throws {
        let control = SemanticMetadataRecoveryControl(), query = SemanticQueryProbe()
        let (service, root, _, _) = try await SemanticRealtimeSearchTests().fixture(query: query, makeReader: {
            SemanticRecoveringReader(reader: $0, control: control)
        })
        defer { try? FileManager.default.removeItem(at: root) }
        service.pause(true); service.prepareForSearch()
        try await SemanticFileServiceTests.wait { service.queryState == .idle && query.warmed == 1 }
        control.arm(blockRecovery: true)
        let final = await service.search("如何取回差旅垫付费用", type: .all, limit: 5)
        #expect(final.isEmpty && service.queryState == .degraded)
        #expect(control.reads == 2 && query.calls == 1, "a cold recovery cannot restart either budget")
        await service.clear(removeModel: true)
    }
}
