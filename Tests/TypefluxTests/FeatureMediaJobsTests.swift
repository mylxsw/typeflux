import Foundation
import Testing
import TypefluxMediaProtocol
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureMediaJobsTests {
    @Test func jobsWaitForActualReapingAndCrashedOwnersLoseTheirDisposableFiles() async throws {
        let gate = MediaJobTestGate()
        var busy: [Bool] = []
        let jobs = FeatureMediaJobs(execution: { request, reaped in
            try await gate.run(request.id, reaped: reaped)
            return .init(termination: .exited(0), exitCode: 0, stdout: "fixture", stderr: "", outputTruncated: false)
        })
        jobs.onBusy = { busy.append($0) }
        let requests = try (0..<3).map { _ in try makeJob() }
        defer { requests.forEach { try? FileManager.default.removeItem(atPath: $0.directory) } }
        for request in requests { _ = try jobs.handle(command("media.submit", request)) }
        for _ in 0..<100 where await gate.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.count == 2)
        let waiting = Task { try await jobs.wait(command("media.wait", requests[0].id)) }
        await gate.complete(requests[0].id)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await gate.count == 2, "Returning host work must not release an unreaped helper slot")
        await gate.reap(requests[0].id)
        let reply = try JSONDecoder().decode(FeatureMediaReply.self, from: await waiting.value)
        #expect(reply.finished && reply.result?.stdout == "fixture")
        _ = try jobs.handle(command("media.ack", requests[0].id))
        for _ in 0..<100 where await gate.count < 3 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.count == 3)
        _ = try jobs.handle(command("media.cancel", requests[1].id))
        let cancelled = try JSONDecoder().decode(FeatureMediaReply.self, from: await jobs.wait(command("media.wait", requests[1].id)))
        #expect(cancelled.finished && cancelled.result == nil)
        _ = try jobs.handle(command("media.ack", requests[1].id))
        _ = try jobs.handle(command("media.ownerExited", FeatureRole.chat))
        for _ in 0..<100 where FileManager.default.fileExists(atPath: requests[2].directory) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!FileManager.default.fileExists(atPath: requests[2].directory))
        #expect(!jobs.isBusy && busy.last == false)
        jobs.stop()
    }

    @Test func acceptedQueueIsBoundedAndQueuedCancellationDoesNotStartAHelper() async throws {
        let jobs = FeatureMediaJobs(execution: { _, reaped in
            defer { reaped() }
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        let requests = try (0..<25).map { _ in try makeJob() }
        defer { requests.forEach { try? FileManager.default.removeItem(atPath: $0.directory) } }
        for request in requests.prefix(24) { _ = try jobs.handle(command("media.submit", request)) }
        let refusal = try JSONDecoder().decode(FeatureMediaAdmission.self, from: jobs.handle(command("media.submit", requests[24])))
        #expect(!refusal.accepted)
        _ = try jobs.handle(command("media.cancel", requests[23].id))
        let reply = try JSONDecoder().decode(FeatureMediaReply.self, from: await jobs.wait(command("media.wait", requests[23].id)))
        #expect(reply.finished && reply.result == nil)
        _ = try jobs.handle(command("media.ack", requests[23].id))
        jobs.stop()
        for _ in 0..<100 where jobs.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!jobs.isBusy)
    }

    @Test func queuedDeadlineReturnsBackpressureWithoutStartingAnExtraHelper() async throws {
        var starts = 0
        let jobs = FeatureMediaJobs(execution: { _, reaped in
            starts += 1
            defer { reaped() }
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        })
        var requests = try (0..<3).map { _ in try makeJob() }
        requests[2] = .init(id: requests[2].id, owner: .chat, directory: requests[2].directory,
            input: requests[2].input, timeout: 0.03, outputLimit: 1024)
        defer { requests.forEach { try? FileManager.default.removeItem(atPath: $0.directory) } }
        for request in requests { _ = try jobs.handle(command("media.submit", request)) }
        let reply = try JSONDecoder().decode(FeatureMediaReply.self, from: await jobs.wait(command("media.wait", requests[2].id)))
        #expect(reply.finished && reply.busy && reply.result == nil)
        let completed = try JSONDecoder().decode(FeatureMediaReply.self, from: await jobs.wait(command("media.wait", requests[2].id)))
        #expect(completed.busy)
        #expect(starts == 2)
        _ = try jobs.handle(command("media.ack", requests[2].id))
        jobs.stop()
        for _ in 0..<100 where jobs.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!jobs.isBusy)
    }

    @Test func shutdownCannotAcknowledgeAnUnreapedHelper() async throws {
        let gate = MediaJobTestGate()
        let jobs = FeatureMediaJobs(execution: { request, reaped in
            try await gate.run(request.id, reaped: reaped)
            return .init(termination: .exited(0), exitCode: 0, stdout: "fixture", stderr: "", outputTruncated: false)
        })
        let request = try makeJob()
        defer { try? FileManager.default.removeItem(atPath: request.directory) }
        _ = try jobs.handle(command("media.submit", request))
        for _ in 0..<100 where await gate.count < 1 { try await Task.sleep(for: .milliseconds(2)) }
        await gate.complete(request.id)
        try await Task.sleep(for: .milliseconds(10))
        await #expect(throws: FeatureRPC.Failure.busy) { try await jobs.shutdown(timeout: .milliseconds(30)) }
        #expect(jobs.isBusy)
        await gate.reap(request.id)
        try await jobs.shutdown(timeout: .seconds(1))
        #expect(!jobs.isBusy)
    }

    private func makeJob() throws -> FeatureMediaJob {
        let envelope = MediaRequest(operation: .image)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-media-" + envelope.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return .init(id: envelope.id, owner: .chat, directory: directory.path, input: try JSONEncoder().encode(envelope), timeout: 3, outputLimit: 1024)
    }
    private func command<T: Encodable>(_ action: String, _ value: T) throws -> FeatureCommand {
        .init(destination: .background, action: action, payload: try JSONEncoder().encode(value))
    }
}

private actor MediaJobTestGate {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var reapers: [UUID: @Sendable () -> Void] = [:]
    private(set) var count = 0
    func run(_ id: UUID, reaped: @escaping @Sendable () -> Void) async throws {
        count += 1; reapers[id] = reaped
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func complete(_ id: UUID) { pending.removeValue(forKey: id)?.resume() }
    func reap(_ id: UUID) { reapers.removeValue(forKey: id)?() }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()); reap(id) }
}
