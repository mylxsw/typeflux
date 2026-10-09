import Testing

/// Runs a test case only while no other `.exclusiveUIState` test case is running.
///
/// Swift Testing runs suites in parallel. `@MainActor` suites still interleave at every
/// `await`, so tests that host windows, send native events, read the key window or first
/// responder, switch `AppLocalization.shared`, or wait on main-thread deadlines can observe
/// each other's state. `.serialized` only orders the tests inside one suite; this trait
/// orders them across every suite that carries it. Tests without it keep running in parallel.
struct ExclusiveUIStateTrait: SuiteTrait, TestTrait, TestScoping {
    var lock: ExclusiveUIStateLock = .shared

    var isRecursive: Bool { true }

    func scopeProvider(for _: Test, testCase: Test.Case?) -> Self? {
        // Lock each test case, not a whole suite, so other suites can run in between.
        testCase == nil ? nil : self
    }

    func provideScope(
        for _: Test,
        testCase _: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await lock.withLock(function)
    }
}

extension Trait where Self == ExclusiveUIStateTrait {
    /// The suite or test uses process-wide AppKit, focus, localization or timing state.
    static var exclusiveUIState: Self { Self() }
}

/// A FIFO async lock shared by every `.exclusiveUIState` test case.
actor ExclusiveUIStateLock {
    static let shared = ExclusiveUIStateLock()
    /// The locks the current task already holds, so a test nested in two exclusive suites
    /// does not wait for itself.
    @TaskLocal private static var held: Set<ObjectIdentifier> = []

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isLocked: Bool { locked }
    var waiterCount: Int { waiters.count }

    nonisolated func withLock(_ body: @Sendable () async throws -> Void) async throws {
        let id = ObjectIdentifier(self)
        if Self.held.contains(id) {
            try await body()
            return
        }
        await acquire()
        do {
            try await Self.$held.withValue(Self.held.union([id])) { try await body() }
        } catch {
            await release()
            throw error
        }
        await release()
    }

    func acquire() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock to the longest waiter, or unlocks when nobody waits.
    func release() {
        precondition(locked, "release() without acquire()")
        guard !waiters.isEmpty else {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
