import Foundation
import Testing
@testable import Typeflux

private final class RegistryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] { lock.withLock { entries } }
    func append(_ value: String) { lock.withLock { entries.append(value) } }
}

private actor RegistryGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@Suite("Module dependency lifecycle")
struct ModuleRegistryTests {
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Lifecycle did not settle")
    }

    private func handle(_ name: String, _ log: RegistryLog) -> ModuleHandle<Int> {
        ModuleHandle(factory: { log.append("start " + name); return 1 },
                     cleanup: { _ in log.append("stop " + name) })
    }

    @Test func orderedStartReverseStopAndStableHandles() async throws {
        let log = RegistryLog()
        let a = handle("a", log), b = handle("b", log), c = handle("c", log)
        let registry = ModuleRegistry([
            .init(.notebook, handle: c, dependencies: [.wordBook]),
            .init(.wordBook, handle: b, dependencies: [.conversations]),
            .init(.conversations, handle: a)
        ])
        await #expect(throws: ModuleFailure.disabled) { try await c.perform { $0 } }
        try await registry.start(.notebook)
        #expect(log.values == ["start a", "start b", "start c"])
        #expect(try await c.perform { $0 } == 1)
        await registry.disable(.wordBook)
        #expect(log.values.suffix(2) == ["stop c", "stop b"])
        #expect(try await a.perform { $0 } == 1)
        await #expect(throws: ModuleFailure.disabled) { try await c.perform { $0 } }
        try await registry.start(.notebook)
        #expect(log.values.suffix(2) == ["start b", "start c"])
        registry.preventNewWork()
        await #expect(throws: ModuleFailure.disabled) { try await a.perform { $0 } }
        await registry.shutdown()
        #expect(log.values.suffix(3) == ["stop c", "stop b", "stop a"])
        await #expect(throws: ModuleRegistryFailure.disabled) { try await registry.start(.notebook) }
    }

    @Test func invalidGraphsNeverRunFactories() async {
        let log = RegistryLog(), a = ModuleHandle(factory: { 1 })
        let b = handle("b", log)
        let graphs: [([ModuleRegistration], ModuleRegistryFailure)] = [
            ([.init(.notebook, handle: a), .init(.notebook, handle: b)], .duplicate),
            ([.init(.notebook, handle: b, dependencies: [.wordBook])], .unknownDependency),
            ([.init(.notebook, handle: a, dependencies: [.wordBook]),
              .init(.wordBook, handle: b, dependencies: [.notebook])], .cycle)
        ]
        for (graph, failure) in graphs {
            let registry = ModuleRegistry(graph)
            await #expect(throws: failure) { try await registry.start(.notebook) }
            #expect(!(await registry.startAll()).isEmpty)
            await registry.shutdown()
        }
        let empty = ModuleRegistry([])
        await #expect(throws: ModuleRegistryFailure.unknownModule) { try await empty.start(.notebook) }
        await empty.disable(.notebook)
        #expect(log.values.isEmpty)
    }

    @Test func failedDependencyDoesNotBlockIndependentDomain() async throws {
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let log = RegistryLog()
        let a = ModuleHandle<Int>(policy: policy, factory: { throw ModuleFailure.unavailable })
        let b = handle("b", log), c = handle("c", log)
        let registry = ModuleRegistry([.init(.wordBook, handle: b, dependencies: [.conversations]),
                                       .init(.conversations, handle: a), .init(.notebook, handle: c)])
        let failures = await registry.startAll()
        #expect(failures[.wordBook] != nil)
        #expect(failures[.conversations] != nil)
        #expect(failures[.notebook] == nil)
        #expect(log.values == ["start c"])
        await registry.shutdown()
    }

    @Test func concurrentStartsShareFactoryAndDisableFencesPendingDescendant() async throws {
        let gate = RegistryGate(), log = RegistryLog()
        let a = ModuleHandle(factory: { log.append("start a"); await gate.wait(); return 1 })
        let b = handle("b", log)
        let registry = ModuleRegistry([.init(.conversations, handle: a),
                                       .init(.notebook, handle: b, dependencies: [.conversations])])
        let first = Task { try await registry.start(.notebook) }
        let second = Task { try await registry.start(.conversations) }
        try await eventually { log.values.count == 1 }
        await registry.disable(.notebook)
        await gate.open()
        await #expect(throws: ModuleRegistryFailure.invalidated) { try await first.value }
        try await second.value
        #expect(log.values == ["start a"])
        try await registry.start(.notebook)
        await registry.shutdown()
    }

    @Test func dependencyFailureFencesOperationsAndRetiresDependents() async throws {
        var policy = ModulePolicy(); policy.automaticallyRecover = false
        let log = RegistryLog()
        let a = ModuleHandle(policy: policy, factory: { 1 })
        let b = handle("b", log)
        let registry = ModuleRegistry([.init(.conversations, handle: a),
                                       .init(.notebook, handle: b, dependencies: [.conversations])])
        try await registry.start(.notebook)
        await #expect(throws: ModuleFailure.unavailable) {
            try await a.perform { _ in throw ModuleFailure.unavailable }
        }
        await #expect(throws: ModuleFailure.disabled) { try await b.perform { $0 } }
        try await eventually { log.values.contains("stop b") }
        await registry.shutdown()
    }

    @Test func cancellationAndShutdownCannotResurrectStartup() async throws {
        let gate = RegistryGate(), log = RegistryLog()
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let a = ModuleHandle(policy: policy, factory: { log.append("start"); await gate.wait(); return 1 },
                             cleanup: { _ in log.append("stop") })
        let registry = ModuleRegistry([.init(.notebook, handle: a)])
        let task = Task { try await registry.start(.notebook) }
        try await eventually { log.values.count == 1 }
        task.cancel()
        await registry.shutdown()
        await #expect(throws: (any Error).self) { try await task.value }
        await gate.open()
        try await eventually { log.values == ["start", "stop"] }
        #expect(await a.supervisor.health().state == .disabled)
        let cancelled = Task { try Task.checkCancellation(); try await registry.start(.notebook) }
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
    }

    @Test func healthObservationKeepsLatestAndBoundsSubscribers() async throws {
        let module = ModuleHandle(factory: { 1 })
        let channel = module.health
        let streams = try (0..<16).map { _ in try channel.observe() }
        #expect(throws: ModuleFailure.overloaded) { try channel.observe() }
        try await module.start()
        await module.shutdown()
        var iterator = streams[0].makeAsyncIterator()
        #expect(await iterator.next()?.state == .disabled)
        var latest = try channelForReadyModule().observe().makeAsyncIterator()
        #expect(await latest.next()?.state == .ready)
        let observer = Task { for await _ in streams[1] { if Task.isCancelled { return } } }
        observer.cancel()
        await observer.value
        _ = try channel.observe()
    }

    @Test func dependencyLossDuringFactoryAndOperationCannotLeaveWaitersHung() async throws {
        let dependency = channelForReadyModule(), factoryGate = RegistryGate(), operationGate = RegistryGate()
        let log = RegistryLog()
        let module = ModuleHandle(factory: { await factoryGate.wait(); return 1 },
                                  cleanup: { _ in log.append("retired") })
        module.supervisor.admission.require([dependency])
        let startup = Task { try await module.start() }
        try await eventually { await module.supervisor.health().state == .starting }
        dependency.publish(ModuleHealth(state: .disabled, generation: UUID(), pendingStarts: 0,
            activeOperations: 0, hasLifecycleWork: false, failure: .disabled))
        await factoryGate.open()
        await #expect(throws: ModuleFailure.disabled) { try await startup.value }
        try await eventually { log.values.count == 1 }
        await module.shutdown()

        let available = channelForReadyModule()
        let operationModule = ModuleHandle(factory: { 1 })
        operationModule.supervisor.admission.require([available])
        let operation = Task { try await operationModule.perform { _ in await operationGate.wait(); return 2 } }
        try await eventually { await operationModule.supervisor.health().activeOperations == 1 }
        available.publish(ModuleHealth(state: .degraded, generation: UUID(), pendingStarts: 0,
            activeOperations: 0, hasLifecycleWork: false, failure: .unavailable))
        await operationGate.open()
        await #expect(throws: ModuleFailure.invalidated) { try await operation.value }
        await operationModule.shutdown()
    }

    @Test func observerExhaustionFailsClosedBeforeStartingDependencies() async throws {
        let a = ModuleHandle(factory: { 1 }), b = ModuleHandle(factory: { 2 })
        let streams = try (0..<16).map { _ in try a.health.observe() }
        let registry = ModuleRegistry([.init(.conversations, handle: a),
                                       .init(.notebook, handle: b, dependencies: [.conversations])])
        await #expect(throws: ModuleRegistryFailure.observationUnavailable) { try await registry.start(.notebook) }
        #expect(streams.count == 16)
        await registry.shutdown()
    }

    @Test func startupBatchDoesNotReenableAModuleDisabledWhileAnotherStarts() async throws {
        let gate = RegistryGate(), log = RegistryLog()
        let a = ModuleHandle(factory: { log.append("a"); await gate.wait(); return 1 })
        let b = handle("b", log)
        let registry = ModuleRegistry([.init(.conversations, handle: a), .init(.notebook, handle: b)])
        let batch = Task { await registry.startAll() }
        try await eventually { log.values == ["a"] }
        await registry.disable(.notebook)
        await gate.open()
        #expect(await batch.value[.notebook] == .invalidated)
        #expect(log.values == ["a"])
        await registry.shutdown()
    }

    @Test func uncooperativeChildKeepsDependencyOwnedAfterBoundedStop() async throws {
        let gate = RegistryGate(), log = RegistryLog()
        let a = handle("a", log)
        var policy = ModulePolicy(); policy.cleanupTimeout = 0.03
        let b = ModuleHandle(policy: policy, factory: { 1 }, cleanup: { _ in
            log.append("child cleanup"); await gate.wait()
        })
        let registry = ModuleRegistry([.init(.conversations, handle: a),
                                       .init(.notebook, handle: b, dependencies: [.conversations])])
        try await registry.start(.notebook)
        await registry.shutdown()
        #expect(log.values == ["start a", "child cleanup"])
        await #expect(throws: ModuleFailure.disabled) { try await a.perform { $0 } }
        await gate.open()
        try await eventually { await !b.supervisor.health().hasLifecycleWork }
        await registry.shutdown()
        #expect(log.values.last == "stop a")
    }

    @Test func overlappingDependencyRetirementAndShutdownShareOrderedCleanup() async throws {
        let gate = RegistryGate(), log = RegistryLog()
        let a = handle("a", log), b = handle("b", log)
        let c = ModuleHandle(factory: { 1 }, cleanup: { _ in
            log.append("stop c"); await gate.wait()
        })
        let registry = ModuleRegistry([.init(.conversations, handle: a),
            .init(.wordBook, handle: b, dependencies: [.conversations]),
            .init(.notebook, handle: c, dependencies: [.wordBook])])
        try await registry.start(.notebook)
        let disabling = Task { await registry.disable(.wordBook) }
        try await eventually { log.values.contains("stop c") }
        let shutdown = Task { await registry.shutdown() }
        try await Task.sleep(for: .milliseconds(10))
        #expect(!log.values.contains("stop a") && !log.values.contains("stop b"))
        await gate.open()
        await shutdown.value
        await disabling.value
        #expect(log.values.suffix(3) == ["stop c", "stop b", "stop a"])
    }

    private func channelForReadyModule() -> ModuleHealthChannel {
        let channel = ModuleHealthChannel()
        channel.publish(ModuleHealth(state: .ready, generation: UUID(), pendingStarts: 0,
                                     activeOperations: 0, hasLifecycleWork: false, failure: nil))
        return channel
    }
}
