import Darwin
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized)
struct FeatureRPCTests {
    @Test func peerClosurePersistsTheTransportCause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AskFailureDiagnostics(directory: directory)
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let client = try FeatureRPC(descriptor: descriptors[0], diagnostics: diagnostics)
        let server = try FeatureRPC(descriptor: descriptors[1])
        await client.start { _, data in data }; await server.start { _, data in data }
        await server.stop()
        for _ in 0..<100 {
            await diagnostics.flush()
            if try AskFailureDiagnostics.read(directory: directory).contains(where: { $0.reason == .peerClosed }) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let events = try AskFailureDiagnostics.read(directory: directory)
        #expect(events.contains { $0.reason == .peerClosed && $0.operation == .rpcRead })
        await client.stop()
    }

    @Test func closingAnIdlePeerWakesItsReader() async throws {
        let (a, b) = try pair()
        await a.start { _, data in data }
        await b.start { _, data in data }
        try await Task.sleep(for: .milliseconds(30))
        await b.stop()
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: FeatureRPC.Failure.unavailable) {
            try await a.request("closed", payload: Data(), timeout: .milliseconds(200))
        }
        await a.stop()
    }

    @Test func incompletePayloadStillHasABoundedReadDeadline() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let peer = try FeatureRPC(descriptor: descriptors[0])
        defer { close(descriptors[1]) }
        await peer.start { _, data in data }
        var size = UInt32(100).bigEndian
        _ = withUnsafeBytes(of: &size) { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(5300))
        await #expect(throws: FeatureRPC.Failure.unavailable) {
            try await peer.request("closed", payload: Data(), timeout: .milliseconds(200))
        }
        await peer.stop()
    }

    @Test func progressingFrameIsNotDisconnectedAfterFiveSeconds() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        #expect(fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0)
        let peer = try FeatureRPC(descriptor: descriptors[0]), counter = FeatureRequestCounter()
        defer { close(descriptors[1]) }
        await peer.start { _, data in await counter.increment(); return data }
        let message = FeatureRPC.Message(version: 1, id: UUID(), method: "slow-frame", payload: Data([42]), failure: nil)
        let payload = try JSONEncoder().encode(message)
        var size = UInt32(payload.count).bigEndian
        #expect(withUnsafeBytes(of: &size) { Darwin.write(descriptors[1], $0.baseAddress, $0.count) } == 4)
        let chunks = [0, payload.count / 3, payload.count * 2 / 3, payload.count]
        for index in 0..<3 {
            try await Task.sleep(for: .milliseconds(2100))
            let chunk = payload.subdata(in: chunks[index]..<chunks[index + 1])
            #expect(chunk.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) } == chunk.count)
        }
        for _ in 0..<100 where await counter.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await counter.count == 1)
        await peer.stop()
    }

    private func pair() throws -> (FeatureRPC, FeatureRPC) {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (try FeatureRPC(descriptor: descriptors[0]), try FeatureRPC(descriptor: descriptors[1]))
    }

    @Test func idleConnectionsDoNotExhaustTheSharedExecutor() async throws {
        var channels: [(FeatureRPC, FeatureRPC)] = []
        for _ in 0..<32 {
            let (a, b) = try pair()
            await a.start { _, data in data }
            await b.start { _, data in data }
            channels.append((a, b))
        }
        for (a, b) in channels {
            let reply: Int = try await a.call("echo", 42, timeout: .seconds(2))
            #expect(reply == 42)
            await a.stop(); await b.stop()
        }
    }

    @Test func concurrentBidirectionalRequestsKeepTheirOwnReplies() async throws {
        let (a, b) = try pair()
        await a.start { _, data in data }
        await b.start { method, data in
            if method == "slow" { try await Task.sleep(for: .milliseconds(100)) }
            return data
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<24 {
                group.addTask {
                    let peer = i.isMultiple(of: 2) ? a : b
                    let result: Int = try await peer.call(i == 0 ? "slow" : "echo", i)
                    #expect(result == i)
                }
            }
            try await group.waitForAll()
        }
        await a.stop(); await b.stop()
    }

    @Test func hungRequestDoesNotBlockAnotherRequestAndNeverReplays() async throws {
        let (a, b) = try pair(), counter = FeatureRequestCounter()
        await a.start { _, data in data }
        await b.start { method, data in
            await counter.increment()
            if method == "slow" { try await Task.sleep(for: .milliseconds(300)) }
            return data
        }
        let slow = Task { try await a.request("slow", payload: Data(), timeout: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(20))
        let fast = try await a.request("fast", payload: Data([1]), timeout: .milliseconds(100))
        #expect(fast == Data([1]))
        await #expect(throws: FeatureRPC.Failure.timedOut) { try await slow.value }
        try await Task.sleep(for: .milliseconds(350))
        #expect(await counter.count == 2)
        #expect(try await a.request("stillOpen", payload: Data([2])) == Data([2]))
        await a.stop(); await b.stop()
    }

    @Test func cancellationAndClosureResolvePendingCalls() async throws {
        let (a, b) = try pair()
        await a.start { _, data in data }
        await b.start { _, _ in try await Task.sleep(for: .seconds(10)); return Data() }
        let cancelled = Task { try await a.request("cancel", payload: Data()) }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: FeatureRPC.Failure.cancelled) { try await cancelled.value }
        let closing = Task { try await a.request("close", payload: Data()) }
        try await Task.sleep(for: .milliseconds(30))
        await b.stop()
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await closing.value }
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await a.request("closed", payload: Data()) }
        await a.stop()
    }

    @Test(arguments: [false, true])
    func cancelledAndTimedOutCallsStopWorkAcrossForwardedChannels(timesOut: Bool) async throws {
        let (client, relayInput) = try pair(), (relayOutput, server) = try pair()
        let entered = FeatureRequestCounter(), cancelled = FeatureRequestCounter()
        await client.start { _, data in data }
        await relayInput.start { method, data in try await relayOutput.request(method, payload: data) }
        await relayOutput.start { _, data in data }
        await server.start { method, data in
            guard method == "search" else { return data }
            await entered.increment()
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                if Task.isCancelled { await cancelled.increment() }
                throw error
            }
            return data
        }
        let request = Task {
            try await client.request("search", payload: Data(), timeout: timesOut ? .milliseconds(500) : .seconds(5))
        }
        for _ in 0..<200 where await entered.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await entered.count == 1)
        if !timesOut { request.cancel() }
        await #expect(throws: timesOut ? FeatureRPC.Failure.timedOut : .cancelled) { try await request.value }
        for _ in 0..<200 where await cancelled.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await cancelled.count == 1, "Both forwarding hops must propagate cancellation to the computation")
        #expect(try await client.request("echo", payload: Data([42])) == Data([42]))
        await client.stop(); await relayInput.stop(); await relayOutput.stop(); await server.stop()
    }

    @Test func invalidRequestsAndDescriptorAreRejected() async throws {
        let descriptor = open("/dev/null", O_RDONLY)
        #expect(throws: FeatureRPC.Failure.invalidMessage) { try FeatureRPC(descriptor: descriptor) }
        let (a, b) = try pair()
        for name in ["", "_cancel", String(repeating: "a", count: 129)] {
            await #expect(throws: FeatureRPC.Failure.invalidMessage) { try await a.request(name, payload: Data()) }
        }
        for timeout in [Duration.zero, .seconds(181)] {
            await #expect(throws: FeatureRPC.Failure.invalidMessage) { try await a.request("echo", payload: Data(), timeout: timeout) }
        }
        await a.stop(); await b.stop()
    }

    @Test func malformedFrameClosesOnlyItsOwnChannel() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let a = try FeatureRPC(descriptor: descriptors[0])
        await a.start { _, data in data }
        var bad: UInt32 = .max
        _ = withUnsafeBytes(of: &bad) { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await a.request("echo", payload: Data()) }
        close(descriptors[1]); await a.stop()
        let (good, other) = try pair()
        await good.start { _, data in data }; await other.start { _, data in data }
        #expect(try await good.request("echo", payload: Data([9])) == Data([9]))
        await good.stop(); await other.stop()
    }

    @Test func requestBudgetRejectsExcessWithoutBlockingOtherChannels() async throws {
        let (a, b) = try pair(), entered = FeatureRequestCounter()
        await a.start { _, data in data }
        await b.start { _, _ in await entered.increment(); try await Task.sleep(for: .seconds(10)); return Data() }
        let requests = (0..<32).map { _ in Task { try await a.request("hold", payload: Data()) } }
        for _ in 0..<100 {
            if await entered.count == 32 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await entered.count == 32)
        await #expect(throws: FeatureRPC.Failure.busy) { try await a.request("excess", payload: Data()) }
        for request in requests { request.cancel(); _ = try? await request.value }
        await a.stop(); await b.stop()
    }
}

private actor FeatureRequestCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
