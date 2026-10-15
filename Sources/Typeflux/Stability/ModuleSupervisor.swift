import Foundation

// Lifecycle transitions stay together so resource ownership can be audited in one place.
// swiftlint:disable type_body_length
/// One independently recoverable fault domain. Factories and operations run off
/// this actor. Cancellation revokes delivery, not ownership: uncooperative work
/// stays counted until it actually returns. A replacement never overlaps it.
actor ModuleSupervisor<Service: Sendable> {
    private struct Operation {
        let generation: UUID
        let task: Task<Void, Never>
        let timer: Task<Void, Never>
        let fail: (any Error) -> Void
    }

    nonisolated let admission = ModuleAdmission()
    private let policy: ModulePolicy
    private let factory: @Sendable () async throws -> Service
    private let cleanup: @Sendable (Service) async -> Void
    private let classify: @Sendable (any Error) -> ModuleFailureDisposition
    private let uptime: @Sendable () -> TimeInterval
    private var budget = ModuleRecoveryBudget()
    private var state: ModuleState = .stopped
    private var generation = UUID()
    private var failure: ModuleFailure?
    private var service: Service?
    private var operations: [UUID: Operation] = [:]
    private var startup: Task<Void, Never>?
    private var lifecycleTimer: Task<Void, Never>?
    private var cleaning: Task<Void, Never>?
    private var cleanupID: UUID?
    private var recovery: Task<Void, Never>?
    private var waiters: [UUID: ModuleReply<ModuleLease<Service>>] = [:]
    private var needsRecovery = false
    private var automaticRetryAllowed = true

    init(policy: ModulePolicy = .init(),
         factory: @escaping @Sendable () async throws -> Service,
         cleanup: @escaping @Sendable (Service) async -> Void = { _ in },
         classify: @escaping @Sendable (any Error) -> ModuleFailureDisposition = { _ in .recover },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.policy = policy
        self.factory = factory
        self.cleanup = cleanup
        self.classify = classify
        self.uptime = uptime
    }

    func health() -> ModuleHealth {
        ModuleHealth(state: admission.permitsWork ? state : .disabled, generation: generation,
                     pendingStarts: waiters.count, activeOperations: operations.count,
                     hasLifecycleWork: startup != nil || cleaning != nil, failure: failure)
    }

    private func acquire() async throws -> ModuleLease<Service> {
        try Task.checkCancellation()
        guard policy.isValid else { throw ModuleFailure.invalidPolicy }
        guard admission.permitsWork else { throw ModuleFailure.disabled }
        if state == .ready, let service { return ModuleLease(service: service, generation: generation) }
        guard cleaning == nil, operations.isEmpty, !needsRecovery,
              budget.permitsAttempt(at: uptime()), automaticRetryAllowed else { throw ModuleFailure.unavailable }
        guard waiters.count < policy.maxInFlight else { throw ModuleFailure.overloaded }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = ModuleReply(continuation)
                if startup == nil { launchFactory() }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// This method never calls an operation twice, including after recovery.
    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (Service) async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire()
        try Task.checkCancellation()
        guard admission.permitsWork, state == .ready, lease.generation == generation else {
            throw ModuleFailure.unavailable
        }
        guard operations.count < policy.maxInFlight else { throw ModuleFailure.overloaded }
        let id = UUID(), current = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reply = ModuleReply(continuation)
                let task = Task.detached { [admission] in
                    let result: Result<Value, any Error>
                    do {
                        try Task.checkCancellation()
                        guard admission.permitsWork else { throw ModuleFailure.disabled }
                        result = .success(try await operation(lease.service))
                    } catch { result = .failure(error) }
                    await self.completed(id, generation: current, result: result, reply: reply)
                }
                let timer = timer(after: policy.operationTimeout) { await self.expired(id) }
                operations[id] = Operation(generation: current, task: task, timer: timer,
                                           fail: { reply.finish(.failure($0)) })
            }
        } onCancel: {
            Task { await self.cancelOperation(id) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        admission.setEnabled(enabled)
        if admission.permitsWork {
            if state == .disabled { state = .stopped }
            automaticRetryAllowed = true
            retireIfPossible()
        } else { stop() }
    }

    func shutdown() {
        admission.shutdown()
        stop()
    }

    /// Explicit retry clears a configuration/permission hold, but respects the
    /// rolling failure budget and outstanding work. It never retries an action.
    func retry() {
        guard admission.permitsWork else { return }
        automaticRetryAllowed = true
        retireIfPossible()
        if !needsRecovery, state != .ready, startup == nil, cleaning == nil { scheduleRecovery() }
    }

    private func stop() {
        invalidate(with: ModuleFailure.disabled)
        state = .disabled
        retireIfPossible()
    }

    private func launchFactory() {
        recovery?.cancel()
        recovery = nil
        state = .starting
        let current = generation
        startup = Task.detached { [factory, admission] in
            let result: Result<Service, any Error>
            do {
                try Task.checkCancellation()
                guard admission.permitsWork else { throw ModuleFailure.disabled }
                result = .success(try await factory())
            } catch { result = .failure(error) }
            await self.factoryCompleted(result, generation: current)
        }
        lifecycleTimer = timer(after: policy.startupTimeout) { await self.factoryExpired(current) }
    }

    private func factoryCompleted(_ result: Result<Service, any Error>, generation current: UUID) {
        startup = nil
        lifecycleTimer?.cancel()
        lifecycleTimer = nil
        guard current == generation, admission.permitsWork else {
            if case let .success(value) = result { service = value }
            retireIfPossible()
            return
        }
        switch result {
        case let .success(value):
            service = value
            state = .ready
            failure = nil
            budget.succeeded(at: uptime())
            finishWaiters(.success(ModuleLease(service: value, generation: current)))
        case let .failure(error):
            finishWaiters(.failure(error))
            failed(error, disposition: classify(error))
        }
    }

    private func factoryExpired(_ current: UUID) {
        guard current == generation, startup != nil else { return }
        failed(ModuleFailure.startupTimeout, disposition: .recover)
    }

    private func completed<Value: Sendable>(_ id: UUID, generation current: UUID,
                                            result: Result<Value, any Error>, reply: ModuleReply<Value>) {
        let operation = operations.removeValue(forKey: id)
        operation?.timer.cancel()
        guard current == generation, admission.permitsWork else {
            reply.finish(.failure(ModuleFailure.invalidated))
            retireIfPossible()
            return
        }
        // Cancellation revokes delivery, but a storage failure still invalidates
        // the instance. Stale generations returned above cannot spend the budget.
        let delivered = reply.finish(result)
        if case let .failure(error) = result, !(error is CancellationError) {
            let disposition = classify(error)
            if disposition != .operationOnly { failed(error, disposition: disposition) }
        } else if delivered {
            budget.succeeded(at: uptime())
        }
        retireIfPossible()
    }

    private func expired(_ id: UUID) {
        guard let operation = operations[id], operation.generation == generation, state == .ready else { return }
        operation.fail(ModuleFailure.operationTimeout)
        failed(ModuleFailure.operationTimeout, disposition: .recover)
    }

    private func cancelOperation(_ id: UUID) {
        guard let operation = operations[id] else { return }
        operation.fail(CancellationError())
        operation.task.cancel()
        // Keep its deadline: an uncooperative cancellation must eventually
        // quarantine this generation instead of silently staying ready forever.
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.finish(.failure(CancellationError()))
    }

    private func failed(_ error: any Error, disposition: ModuleFailureDisposition) {
        budget.failed(at: uptime())
        automaticRetryAllowed = disposition != .waitForExplicitRetry
        invalidate(with: error)
        state = .recovering
        if case .circuitOpen = budget.state { state = .circuitOpen }
        if startup != nil || !operations.isEmpty { state = .degraded }
        retireIfPossible()
    }

    private func invalidate(with error: any Error) {
        generation = UUID()
        failure = (error as? ModuleFailure) ?? .unavailable
        needsRecovery = true
        recovery?.cancel()
        recovery = nil
        lifecycleTimer?.cancel()
        lifecycleTimer = nil
        startup?.cancel()
        finishWaiters(.failure(error))
        for operation in operations.values {
            operation.timer.cancel()
            operation.task.cancel()
            operation.fail(ModuleFailure.invalidated)
        }
    }

    private func finishWaiters(_ result: Result<ModuleLease<Service>, any Error>) {
        let pending = waiters.values
        waiters.removeAll()
        for reply in pending { reply.finish(result) }
    }

    private func retireIfPossible() {
        guard needsRecovery, startup == nil, operations.isEmpty, cleaning == nil else { return }
        if let service {
            self.service = nil
            let id = UUID()
            cleanupID = id
            cleaning = Task.detached { [cleanup] in
                await cleanup(service)
                await self.cleanupCompleted(id)
            }
            lifecycleTimer = timer(after: policy.cleanupTimeout) { await self.cleanupExpired(id) }
        } else {
            needsRecovery = false
            scheduleRecovery()
        }
    }

    private func cleanupExpired(_ id: UUID) {
        guard cleaning != nil, cleanupID == id else { return }
        failure = .cleanupTimeout
        state = admission.permitsWork ? .degraded : .disabled
        cleaning?.cancel()
        // Keep cleaning occupied until it returns; no replacement can overlap.
    }

    private func cleanupCompleted(_ id: UUID) {
        guard cleanupID == id else { return }
        cleanupID = nil
        cleaning = nil
        lifecycleTimer?.cancel()
        lifecycleTimer = nil
        needsRecovery = false
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard admission.permitsWork else { state = .disabled; return }
        guard policy.isValid else { state = .degraded; failure = .invalidPolicy; return }
        state = .recovering
        let delay: TimeInterval
        switch budget.state {
        case .available: delay = 0
        case let .waiting(until): delay = max(0, until - uptime())
        case let .circuitOpen(until): state = .circuitOpen; delay = max(0, until - uptime())
        }
        guard automaticRetryAllowed else { state = .degraded; return }
        guard policy.automaticallyRecover, recovery == nil else { return }
        let current = generation
        recovery = timer(after: delay) { await self.recover(current) }
    }

    private func recover(_ current: UUID) {
        recovery = nil
        guard admission.permitsWork, current == generation, !needsRecovery,
              startup == nil, cleaning == nil, operations.isEmpty, state != .ready,
              budget.permitsAttempt(at: uptime()), automaticRetryAllowed else { return }
        launchFactory()
    }

    private func timer(after seconds: TimeInterval, _ action: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled else { return }
            await action()
        }
    }
} // swiftlint:enable type_body_length

private struct ModuleLease<Service: Sendable>: Sendable {
    let service: Service
    let generation: UUID
}

/// The supervisor is the sole completion owner. A late result cannot complete a
/// timed-out/cancelled continuation a second time.
private final class ModuleReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
        return pending != nil
    }
}
