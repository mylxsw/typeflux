import Foundation
import Testing
@testable import Typeflux

private final class ValidationReader: AskFileReading {
    var calls = 0
    var stall = false
    var version = "current"
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        calls += 1
        while stall, !isCancelled() {
            Thread.sleep(forTimeInterval: 0.001)
        }
        if isCancelled() {
            throw AskFileReadError.cancelled
        }
        return .init(path: request.path, modified: Date(timeIntervalSince1970: 1), version: version)
    }
}

private final class SlowPreparationReader: AskFileReading, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    func read(_ request: AskFileReadRequest, isCancelled: () -> Bool) throws -> AskFileReadResponse {
        if request.operation == .resolve {
            started.signal()
            while !isCancelled() {
                Thread.sleep(forTimeInterval: 0.001)
            }
            finished.signal()
            throw AskFileReadError.cancelled
        }
        return .init(path: request.path, modified: Date(timeIntervalSince1970: 1), version: "current")
    }
}

@Suite("Bounded semantic permission validation")
struct SemanticFileValidatorTests {
    @Test func `interactive validation preempts a stalled root prewarm`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = SlowPreparationReader(), validator = SemanticFileValidator(reader: reader)
        let scope = semanticScope(root.path), group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            try? validator.warm(scope: scope, cancelled: { false })
        }
        try #require(reader.started.wait(timeout: .now() + 1) == .success)
        let start = ProcessInfo.processInfo.systemUptime
        let hit = AskFileHit(path: root.path + "/note.txt", name: "note", kind: .file,
                             modified: Date(timeIntervalSince1970: 1), score: 1)
        let result = validator.validateBatch([hit], scope: scope, limit: 1, cancelled: { false })
        #expect(result.complete && result.hits.count == 1)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2)
        #expect(reader.finished.wait(timeout: .now() + 1) == .success)
        #expect(group.wait(timeout: .now() + 1) == .success)
        try validator.warm(scope: scope, cancelled: { true })
    }

    @Test func `deadline is shared by the entire candidate batch and fails closed`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = ValidationReader(), validator = SemanticFileValidator(reader: reader, budget: 0.02)
        let scope = semanticScope(root.path)
        try validator.warm(scope: scope, cancelled: { false })
        let hits = (0 ..< 24).map { AskFileHit(path: root.path + "/file-\($0).txt", name: "file", kind: .file,
                                               modified: Date(timeIntervalSince1970: 1), score: 1) }
        reader.stall = true
        let start = ProcessInfo.processInfo.systemUptime
        let result = validator.validateBatch(hits, scope: scope, limit: 24, cancelled: { false })
        #expect(result.hits.isEmpty && !result.complete)
        #expect(reader.calls == 2, "one stalled file cannot cause 24 timeouts")
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2)
        reader.stall = false
        #expect(validator.validateBatch(hits, scope: scope, limit: 1, cancelled: { false }).hits.count == 1)
    }

    @Test func `permissions and versions are rechecked on every publication`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let reader = ValidationReader(), validator = SemanticFileValidator(reader: reader)
        let hit = AskFileHit(path: root.path + "/note.txt", name: "note", kind: .file,
                             modified: Date(timeIntervalSince1970: 1), score: 1, evidence: .init(
                                 text: "",
                                 version: "current"
                             ))
        let scope = semanticScope(root.path)
        #expect(validator.validate([hit], scope: scope, limit: 1, cancelled: { false }).count == 1)
        reader.version = "changed"
        #expect(validator.validate([hit], scope: scope, limit: 1, cancelled: { false }).isEmpty)
        var denied = scope; denied.excludedPaths = [hit.path]
        let calls = reader.calls
        #expect(validator.validate([hit], scope: denied, limit: 1, cancelled: { false }).isEmpty)
        #expect(reader.calls == calls)
        #expect(validator.validate([hit], scope: scope, limit: 0, cancelled: { false }).isEmpty)
        #expect(!validator.validateBatch([hit], scope: scope, limit: 1, cancelled: { true }).complete)
    }
}
