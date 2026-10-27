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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AskFailureDiagnostics(directory: directory)
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let peer = try FeatureRPC(descriptor: descriptors[0], diagnostics: diagnostics)
        defer { close(descriptors[1]) }
        await peer.start { _, data in data }
        var size = UInt32(100).bigEndian
        _ = withUnsafeBytes(of: &size) { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(5300))
        await #expect(throws: FeatureRPC.Failure.unavailable) {
            try await peer.request("closed", payload: Data(), timeout: .milliseconds(200))
        }
        await diagnostics.flush()
        #expect(try AskFailureDiagnostics.read(directory: directory).contains {
            $0.reason == .frameDeadline && $0.operation == .rpcRead && $0.frameBytes == 100 && $0.transferredBytes == 0
        })
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

    @Test func disconnectedChannelReconnectsWithoutReplayingInterruptedWork() async throws {
        let listener = try FeatureReconnectListener()
        defer { listener.stop() }
        listener.setExpectedPeerPID(getpid())
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let a = try FeatureRPC(descriptor: descriptors[0], reconnect: { try await listener.acceptConnection() })
        let b = try FeatureRPC(descriptor: descriptors[1], reconnect: {
            try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        })
        let entered = FeatureRequestCounter()
        await a.start { _, data in data }
        await b.start { method, data in
            if method == "interrupted" {
                await entered.increment()
                try await Task.sleep(for: .seconds(10))
            }
            return data
        }
        let interrupted = Task { try await a.request("interrupted", payload: Data([1])) }
        for _ in 0..<100 where await entered.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await entered.count == 1)
        #expect(shutdown(descriptors[0], SHUT_RDWR) == 0)
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await interrupted.value }
        var reply: Data?
        for _ in 0..<50 {
            if let value = try? await a.request("echo", payload: Data([42]), timeout: .seconds(1)) {
                reply = value; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reply == Data([42]))
        #expect(await entered.count == 1)
        await a.stop(); await b.stop()
    }

    @Test func stalledFrameTimesOutAndTheSamePeerReconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AskFailureDiagnostics(directory: directory)
        let listener = try FeatureReconnectListener()
        defer { listener.stop() }
        listener.setExpectedPeerPID(getpid())
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[1]) }
        let peer = try FeatureRPC(descriptor: descriptors[0], diagnostics: diagnostics,
                                  reconnect: { try await listener.acceptConnection() })
        await peer.start { _, data in data }
        var length = UInt32(100).bigEndian
        #expect(withUnsafeBytes(of: &length) { Darwin.write(descriptors[1], $0.baseAddress, $0.count) } == 4)
        let partial = Data(repeating: 1, count: 10)
        #expect(partial.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) } == partial.count)
        try await Task.sleep(for: .milliseconds(5300))
        await diagnostics.flush()
        #expect(try AskFailureDiagnostics.read(directory: directory).contains {
            $0.reason == .frameDeadline && $0.frameBytes == 100 && $0.transferredBytes == 10
        })
        let descriptor = try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        let other = try FeatureRPC(descriptor: descriptor)
        await other.start { _, data in data }
        #expect(try await peer.request("echo", payload: Data([42]), timeout: .seconds(3)) == Data([42]))
        await peer.stop(); await other.stop()
    }

    @Test func blockedWriterTimesOutAndTheSamePeerReconnects() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AskFailureDiagnostics(directory: directory)
        let listener = try FeatureReconnectListener()
        defer { listener.stop() }
        listener.setExpectedPeerPID(getpid())
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[1]) }
        let peer = try FeatureRPC(descriptor: descriptors[0], diagnostics: diagnostics,
                                  reconnect: { try await listener.acceptConnection() })
        await peer.start { _, data in data }
        // The other endpoint deliberately stops reading mid-frame.
        let blocked = Task { try await peer.request("blocked", payload: Data(repeating: 1, count: 2 * 1024 * 1024), timeout: .seconds(15)) }
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await blocked.value }
        await diagnostics.flush()
        #expect(try AskFailureDiagnostics.read(directory: directory).contains {
            $0.reason == .frameDeadline && $0.operation == .rpcWrite && ($0.frameBytes ?? 0) > 2 * 1024 * 1024
                && ($0.transferredBytes ?? 0) > 0 && ($0.transferredBytes ?? 0) < ($0.frameBytes ?? 0)
        })
        let descriptor = try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        let other = try FeatureRPC(descriptor: descriptor)
        await other.start { _, data in data }
        #expect(try await peer.request("echo", payload: Data([42]), timeout: .seconds(3)) == Data([42]))
        await peer.stop(); await other.stop()
    }

    @Test func reconnectRejectsAnotherProcessEvenWithTheCapability() async throws {
        let listener = try FeatureReconnectListener()
        defer { listener.stop() }
        listener.setExpectedPeerPID(-1)
        let accepted = Task { try await listener.acceptConnection() }
        let rejected = try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        defer { close(rejected) }
        var byte: UInt8 = 0
        var status: Int = -1
        for _ in 0..<100 {
            status = recv(rejected, &byte, 1, MSG_DONTWAIT)
            if status == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(status == 0)
        listener.setExpectedPeerPID(getpid())
        let valid = try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        defer { close(valid) }
        let server = try await accepted.value
        close(server)
    }

    @Test func waitingForReconnectHonorsCancellationTimeoutAndAdmissionLimit() async throws {
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let peer = try FeatureRPC(descriptor: descriptors[0], reconnect: {
            try await Task.sleep(for: .seconds(30))
            throw FeatureRPC.Failure.unavailable
        })
        let other = try FeatureRPC(descriptor: descriptors[1])
        await peer.start { _, data in data }; await other.start { _, data in data }
        await peer.simulateDisconnect()
        _ = try? await peer.request("settle", payload: Data(), timeout: .milliseconds(250))
        let start = ContinuousClock.now
        await #expect(throws: FeatureRPC.Failure.timedOut) {
            try await peer.request("deadline", payload: Data(), timeout: .milliseconds(150))
        }
        #expect(start.duration(to: .now) < .seconds(1))
        let cancelled = Task { try await peer.request("cancel", payload: Data(), timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        await #expect(throws: FeatureRPC.Failure.cancelled) { try await cancelled.value }
        let waiting = (0..<32).map { _ in Task { try await peer.request("wait", payload: Data(), timeout: .seconds(5)) } }
        try await Task.sleep(for: .milliseconds(250))
        await #expect(throws: FeatureRPC.Failure.busy) {
            try await peer.request("overflow", payload: Data(), timeout: .seconds(1))
        }
        await peer.stop(); await other.stop()
        for task in waiting { _ = try? await task.value }
    }

    @Test func reconnectKeepsUncooperativeWorkInsideTheAdmissionBudget() async throws {
        let listener = try FeatureReconnectListener(), gate = FeatureRequestGate()
        defer { listener.stop(); Task { await gate.release() } }
        listener.setExpectedPeerPID(getpid())
        var descriptors: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let a = try FeatureRPC(descriptor: descriptors[0], reconnect: { try await listener.acceptConnection() })
        let b = try FeatureRPC(descriptor: descriptors[1], reconnect: {
            try await FeatureReconnectListener.connect(path: listener.path, secret: listener.secret, expectedPeerPID: getpid())
        })
        await a.start { _, data in data }
        await b.start { method, data in
            if method == "held" { await gate.wait() }
            return data
        }
        let calls = (0..<32).map { _ in Task { try await a.request("held", payload: Data([1]), timeout: .seconds(10)) } }
        for _ in 0..<200 where await gate.count < 32 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.count == 32)
        #expect(shutdown(descriptors[0], SHUT_RDWR) == 0)
        for call in calls { _ = try? await call.value }
        await #expect(throws: FeatureRPC.Failure.busy) {
            try await a.request("probe", payload: Data(), timeout: .seconds(3))
        }
        await gate.release()
        var reply: Data?
        for _ in 0..<100 {
            if let result = try? await a.request("echo", payload: Data([7]), timeout: .seconds(1)) {
                reply = result; break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reply == Data([7]))
        await a.stop(); await b.stop()
    }

    @Test func cancellingReconnectClosesThePrivateListener() async throws {
        let listener = try FeatureReconnectListener()
        let path = listener.path
        let waiting = Task { try await listener.acceptConnection() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        await #expect(throws: FeatureRPC.Failure.unavailable) { try await waiting.value }
        #expect(!FileManager.default.fileExists(atPath: path))
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

private actor FeatureRequestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiters.count }
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() {
        let active = waiters; waiters.removeAll()
        for waiter in active { waiter.resume() }
    }
}
