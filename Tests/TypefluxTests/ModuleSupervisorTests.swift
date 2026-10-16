import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded module supervision")
// swiftlint:disable:next type_body_length
struct ModuleSupervisorTests {
    private enum Fault: Error { case storage, input, permission }

    private actor Gate<Value: Sendable> {
        private var value: Value?
        private var waiters: [CheckedContinuation<Value, Never>] = []
        func wait() async -> Value {
            if let value { return value }
            return await withCheckedContinuation { waiters.append($0) }
        }
        func open(_ value: Value) {
            self.value = value
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume(returning: value) }
        }
    }

    private struct CounterSnapshot { let factory: Int; let operation: Int; let cleanup: Int }

    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var factories = 0
        private var operations = 0
        private var cleanups = 0
        private var time: TimeInterval = 0
        func factory() -> Int { lock.withLock { factories += 1; return factories } }
        func operation() { lock.withLock { operations += 1 } }
        func cleanup() { lock.withLock { cleanups += 1 } }
        func now() -> TimeInterval { lock.withLock { time } }
        func advance(_ seconds: TimeInterval = 301) { lock.withLock { time += seconds } }
        var counts: CounterSnapshot {
            lock.withLock { CounterSnapshot(factory: factories, operation: operations, cleanup: cleanups) }
        }
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Condition did not become true within two seconds")
    }

    @Test func `invalid policies never construct services`() async {
        var policies: [ModulePolicy] = []
        for value in [Double.nan, .infinity, 0, -1, 86401] {
            var policy = ModulePolicy(); policy.startupTimeout = value; policies.append(policy)
            policy = ModulePolicy(); policy.operationTimeout = value; policies.append(policy)
            policy = ModulePolicy(); policy.cleanupTimeout = value; policies.append(policy)
        }
        for value in [0, 65] {
            var policy = ModulePolicy(); policy.maxInFlight = value; policies.append(policy)
        }
        let counter = Counters()
        for policy in policies {
            let module = ModuleHandle(policy: policy, factory: { counter.factory() })
            await #expect(throws: ModuleFailure.invalidPolicy) { try await module.perform { $0 } }
            await module.supervisor.retry()
            #expect(await module.supervisor.health().failure == .invalidPolicy)
            await module.shutdown()
        }
        #expect(counter.counts.factory == 0)
    }

    @Test func `concurrent startup shares one factory and bounds waiting callers`() async throws {
        let gate = Gate<Int>(), counter = Counters()
        var policy = ModulePolicy(); policy.maxInFlight = 2
        let module = ModuleHandle(policy: policy, factory: { _ = counter.factory(); return await gate.wait() })
        let first = Task { try await module.perform { $0 } }
        try await eventually { counter.counts.factory == 1 }
        let second = Task { try await module.perform { $0 } }
        try await eventually { await module.supervisor.health().pendingStarts == 2 }
        await #expect(throws: ModuleFailure.overloaded) { try await module.perform { $0 } }
        await gate.open(7)
        #expect(try await first.value == 7)
        #expect(try await second.value == 7)
        #expect(counter.counts.factory == 1)
        #expect(await module.supervisor.health().state == .ready)
        await module.shutdown()
    }

    @Test func `cancelled uncooperative operation retains its slot without replay`() async throws {
        let gate = Gate<Int>(), counter = Counters()
        var policy = ModulePolicy(); policy.maxInFlight = 1
        let module = ModuleHandle(policy: policy, factory: { counter.factory() })
        let task = Task { try await module.perform { _ in counter.operation(); return await gate.wait() } }
        try await eventually { counter.counts.operation == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await module.supervisor.health().activeOperations == 1)
        await #expect(throws: ModuleFailure.overloaded) { try await module.perform { $0 } }
        await gate.open(10)
        try await eventually { await module.supervisor.health().activeOperations == 0 }
        #expect(try await module.perform { $0 } == 1)
        #expect(counter.counts.operation == 1)
        await module.shutdown()
    }

    @Test func `deadline rejects late results and replacement waits for operations and cleanup`() async throws {
        let work = Gate<Int>(), cleanup = Gate<Bool>(), counter = Counters()
        var policy = ModulePolicy(); policy.operationTimeout = 0.05; policy.automaticallyRecover = false
        let module = ModuleHandle(policy: policy, factory: { counter.factory() }, cleanup: { _ in
            counter.cleanup(); _ = await cleanup.wait()
        }, uptime: { counter.now() })
        let first = Task { try await module.perform { _ in counter.operation(); return await work.wait() } }
        try await eventually { counter.counts.operation == 1 }
        let original = await module.supervisor.health().generation
        await #expect(throws: ModuleFailure.operationTimeout) { try await first.value }
        #expect(await module.supervisor.health().generation != original)
        #expect(await module.supervisor.health().state == .degraded)
        counter.advance()
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        #expect(counter.counts.cleanup == 0)
        await work.open(9)
        try await eventually { counter.counts.cleanup == 1 }
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        await cleanup.open(true)
        try await eventually { await !module.supervisor.health().hasLifecycleWork }
        #expect(try await module.perform { $0 } == 2)
        #expect(counter.counts.operation == 1)
        await module.shutdown()
    }

    @Test func `startup timeout retains sole factory until stale service is disposed`() async throws {
        let gate = Gate<Int>(), counter = Counters()
        var policy = ModulePolicy(); policy.startupTimeout = 0.03; policy.automaticallyRecover = false
        let module = ModuleHandle(policy: policy, factory: {
            let count = counter.factory()
            return count == 1 ? await gate.wait() : count
        }, cleanup: { _ in counter.cleanup() }, uptime: { counter.now() })
        await #expect(throws: ModuleFailure.startupTimeout) { try await module.perform { $0 } }
        counter.advance()
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        #expect(counter.counts.factory == 1)
        await gate.open(99)
        try await eventually { await !module.supervisor.health().hasLifecycleWork }
        #expect(counter.counts.cleanup == 1)
        #expect(try await module.perform { $0 } == 2)
        await module.shutdown()
    }

    @Test func `cleanup timeout stays quarantined and disable prevents resurrection`() async throws {
        let cleanup = Gate<Bool>(), counter = Counters()
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let module = ModuleHandle(policy: policy, factory: { counter.factory() }, cleanup: { _ in
            counter.cleanup(); _ = await cleanup.wait()
        }, uptime: { counter.now() })
        await #expect(throws: Fault.self) { try await module.perform { _ in throw Fault.storage } }
        try await eventually { await module.supervisor.health().failure == .cleanupTimeout }
        counter.advance()
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        await module.setEnabled(false)
        await #expect(throws: ModuleFailure.disabled) { try await module.perform { $0 } }
        await cleanup.open(true)
        try await eventually { await !module.supervisor.health().hasLifecycleWork }
        #expect(await module.supervisor.health().state == .disabled)
        #expect(counter.counts.factory == 1)
        await module.setEnabled(true)
        #expect(try await module.perform { $0 } == 2)
        await module.shutdown()
        await module.setEnabled(true)
        await module.supervisor.retry()
        await #expect(throws: ModuleFailure.disabled) { try await module.perform { $0 } }
    }

    @Test func `automatic recovery rebuilds service once but does not repeat failed effect`() async throws {
        let counter = Counters()
        let module = ModuleHandle(factory: { counter.factory() })
        await #expect(throws: Fault.self) {
            try await module.perform { _ in counter.operation(); throw Fault.storage }
        }
        try await eventually { await module.supervisor.health().state == .ready }
        #expect(counter.counts.factory == 2)
        #expect(counter.counts.operation == 1)
        #expect(try await module.perform { $0 } == 2)
        await module.shutdown()
    }

    @Test func `repeated failures open circuit and failed probe extends cooldown`() async throws {
        let counter = Counters()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let module = ModuleHandle<Int>(policy: policy, factory: { _ = counter.factory(); throw Fault.storage },
                                       uptime: { counter.now() })
        for delay in [1.0, 2, 4, 300] {
            await #expect(throws: Fault.self) { try await module.perform { $0 } }
            await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
            counter.advance(delay)
        }
        #expect(await module.supervisor.health().state == .circuitOpen)
        await #expect(throws: Fault.self) { try await module.perform { $0 } }
        #expect(counter.counts.factory == 5)
        counter.advance(299)
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        counter.advance(1)
        await #expect(throws: Fault.self) { try await module.perform { $0 } }
        await module.shutdown()
    }

    @Test func `operation errors preserve instance and explicit retry releases configuration hold`() async throws {
        let counter = Counters()
        let module = ModuleHandle(factory: { counter.factory() }, classify: { error in
            if case Fault.input = error { return .operationOnly }
            return .waitForExplicitRetry
        }, uptime: { counter.now() })
        #expect(try await module.perform { $0 } == 1)
        let generation = await module.supervisor.health().generation
        await #expect(throws: Fault.self) { try await module.perform { _ in throw Fault.input } }
        #expect(await module.supervisor.health().generation == generation)
        #expect(try await module.perform { $0 } == 1)
        await #expect(throws: Fault.self) { try await module.perform { _ in throw Fault.permission } }
        try await eventually { await !module.supervisor.health().hasLifecycleWork }
        counter.advance()
        await #expect(throws: ModuleFailure.unavailable) { try await module.perform { $0 } }
        #expect(await module.supervisor.health().state == .degraded)
        await module.supervisor.retry()
        try await eventually { await module.supervisor.health().state == .ready }
        #expect(counter.counts.factory == 2)
        await module.shutdown()
    }

    @Test func `shutdown fences synchronously and discards pending startup and operation results`() async throws {
        let gate = Gate<Int>(), counter = Counters()
        let module = ModuleHandle(factory: { counter.factory() }, cleanup: { _ in counter.cleanup() })
        let task = Task { try await module.perform { _ in counter.operation(); return await gate.wait() } }
        try await eventually { counter.counts.operation == 1 }
        module.preventNewWork()
        await #expect(throws: ModuleFailure.disabled) { try await module.perform { $0 } }
        await module.shutdown()
        await #expect(throws: ModuleFailure.self) { try await task.value }
        await gate.open(99)
        try await eventually { counter.counts.cleanup == 1 }
        #expect(await module.supervisor.health().state == .disabled)
        #expect(counter.counts.factory == 1)

        let startupGate = Gate<Int>()
        let startup = ModuleHandle(factory: { await startupGate.wait() }, cleanup: { _ in counter.cleanup() })
        let pending = Task { try await startup.perform { $0 } }
        try await eventually { await startup.supervisor.health().state == .starting }
        await startup.setEnabled(false)
        await #expect(throws: ModuleFailure.disabled) { try await pending.value }
        await startupGate.open(1)
        try await eventually { counter.counts.cleanup == 2 }
        await startup.shutdown()
    }

    @Test func `cancelling startup waiter never invokes its operation`() async throws {
        let gate = Gate<Int>(), counter = Counters()
        let module = ModuleHandle(factory: { await gate.wait() })
        let task = Task { try await module.perform { _ in counter.operation() } }
        try await eventually { await module.supervisor.health().state == .starting }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open(1)
        try await eventually { await module.supervisor.health().state == .ready }
        #expect(counter.counts.operation == 0)
        await module.shutdown()
    }

    @Test func `simultaneous failures invalidate siblings without a recovery storm`() async throws {
        let gate = Gate<Bool>(), counter = Counters()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let module = ModuleHandle(policy: policy, factory: { counter.factory() }, uptime: { counter.now() })
        #expect(try await module.perform { $0 } == 1)
        let tasks = (0..<8).map { _ in Task {
            try await module.perform { _ in counter.operation(); _ = await gate.wait(); throw Fault.storage }
        } }
        try await eventually { counter.counts.operation == 8 }
        await gate.open(true)
        for task in tasks { await #expect(throws: (any Error).self) { try await task.value } }
        try await eventually {
            let health = await module.supervisor.health()
            return !health.hasLifecycleWork && health.activeOperations == 0
        }
        counter.advance(1)
        #expect(try await module.perform { $0 } == 2, "Only one failure spent the recovery budget")
        await module.shutdown()
    }
    @Test func `late storage error after cancellation still retires the broken service`() async throws {
        let gate = Gate<Bool>(), counter = Counters()
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let module = ModuleHandle(policy: policy, factory: { counter.factory() }, uptime: { counter.now() })
        let task = Task {
            try await module.perform { _ in counter.operation(); _ = await gate.wait(); throw Fault.storage }
        }
        try await eventually { counter.counts.operation == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open(true)
        try await eventually {
            let health = await module.supervisor.health()
            return health.state == .recovering && !health.hasLifecycleWork && health.activeOperations == 0
        }
        counter.advance()
        #expect(try await module.perform { $0 } == 2)
        #expect(counter.counts.operation == 1)
        await module.shutdown()
    }

}
