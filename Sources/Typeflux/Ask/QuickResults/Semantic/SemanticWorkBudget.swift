import CoreGraphics
import Darwin
import Foundation

/// One owner executes background work. Owned CPU children are time-sliced during pipe I/O as well
/// as between checkpoints. Query/voice work uses separate workers and never inherits this task local.
final class SemanticWorkBudget: @unchecked Sendable {
    @TaskLocal static var current: SemanticWorkBudget?
    @TaskLocal static var cancellation: (@Sendable () -> Bool)?
    static var defaultEnabled: Bool {
        !AskFileIndex.isTesting || ProcessInfo.processInfo.environment["TYPEFLUX_SEMANTIC_REFERENCE_BUDGET"] == "1"
    }

    struct Interrupted: Error {}
    enum Waiting: String, Sendable { case priority, memory, thermal, recovery }
    private var waiting: Waiting?
    private let onWaiting: @Sendable (Waiting?) -> Void
    struct State: Equatable { var pressure = 0; var thermal = 0; var active = false; var paused = false }
    struct Statistics: Equatable { var yields = 0; var milliseconds = 0; var interruptions = 0 }
    struct Policy {
        var quantum: TimeInterval = 0.040
        var rest: TimeInterval = 0.040
        var activeQuantum: TimeInterval = 0.010
        var activeRest: TimeInterval = 0.090
        var recovery: TimeInterval = 5
        /// Four document checkpoints retain text priority without waiting for the entire backlog.
        /// The pinned one-thread text reference is about 303 ms of CPU per checkpoint on this host.
        var documentBatches = 4
    }

    private let policy: Policy
    private let state: () -> State
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private var slice: TimeInterval
    private var constrainedUntil: TimeInterval = 0
    private let statisticsLock = NSLock()
    private var counters = Statistics()
    var statistics: Statistics {
        statisticsLock.withLock { counters }
    }

    private final class Resource {
        weak var worker: SemanticEmbeddingWorker?
        init(_ worker: SemanticEmbeddingWorker) {
            self.worker = worker
        }
    }

    private var resources: [Resource] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private let pressureLock = NSLock()
    private var pressure = 0
    private let observeSystem: Bool
    private var nextPressureRead: TimeInterval = 0
    let enabled: Bool
    var documentBatchLimit: Int? {
        enabled ? max(1, policy.documentBatches) : nil
    }

    init(
        policy: Policy = .init(),
        enabled: Bool = SemanticWorkBudget.defaultEnabled,
        paused: @escaping () -> Bool = { false },
        lowPower: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
        state: (() -> State)? = nil,
        onWaiting: @escaping @Sendable (Waiting?) -> Void = { _ in },
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.observeSystem = enabled && state == nil
        self.onWaiting = onWaiting
        self.policy = policy; self.enabled = enabled; self.clock = clock; self.sleep = sleep; slice = clock()
        self.state = state ?? {
            let events: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
            let active = events.contains { CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: $0
            ) < 2 }
            return State(
                thermal: ProcessInfo.processInfo.thermalState.rawValue,
                active: active || lowPower(),
                paused: paused()
            )
        }
        if enabled, state == nil {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: .global(qos: .utility)
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                pressureLock
                    .withLock {
                        self.pressure = source.data.contains(.critical) ? 2 : (source.data.contains(.warning) ? 1 : 0)
                    }
            }
            pressureSource = source; source.resume()
        }
    }

    func perform<Value>(cancelled: @escaping @Sendable () -> Bool, operation: () throws -> Value) throws -> Value {
        try Self.$cancellation.withValue(cancelled) {
            try Self.$current.withValue(self) {
                try checkpoint(cancelled: cancelled)
                return try operation()
            }
        }
    }

    deinit { pressureSource?.cancel() }

    func register(_ worker: SemanticEmbeddingWorker) {
        resources.removeAll { $0.worker == nil }
        resources.append(Resource(worker))
    }

    static func currentPressure() -> Int? {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return level >= 4 ? 2 : (level >= 2 ? 1 : 0)
    }

    private func refreshPressure() {
        guard observeSystem, clock() >= nextPressureRead else { return }
        nextPressureRead = clock() + 1
        if let current = Self.currentPressure() {
            pressureLock.withLock { pressure = current }
        }
    }

    private func setWaiting(_ value: Waiting?) {
        guard waiting != value else { return }
        waiting = value; onWaiting(value)
    }

    /// Returns time deliberately yielded so callers exclude it from child idle deadlines.
    /// Keep resource ownership, cancellation and state checks in one operation.
    @discardableResult
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func checkpoint(child: Process? = nil, cancelled: () -> Bool) throws -> TimeInterval {
        guard !cancelled() else { throw CancellationError() }
        guard enabled else { return 0 }
        let started = clock()
        refreshPressure()
        var value = state()
        value.pressure = max(value.pressure, pressureLock.withLock { pressure })
        let blocked = value.paused || value.pressure >= 2 || value.thermal >= 2
        if value.pressure >= 2 || value.thermal >= 2 {
            constrainedUntil = started + policy.recovery
        }
        // Releasing a long inference, rather than leaving suspended model memory resident, also
        // bounds query/voice priority latency. Its durable job checkpoint is retried after recovery.
        if !blocked && started >= constrainedUntil {
            setWaiting(nil)
        }
        if blocked {
            setWaiting(value.paused ? .priority : (value.pressure >= 2 ? .memory : .thermal))
        }
        if child != nil && blocked {
            statisticsLock.withLock { counters.interruptions += 1 }
            throw Interrupted()
        }
        if blocked || started < constrainedUntil {
            if !blocked {
                setWaiting(.recovery)
            }
            defer { setWaiting(nil) }
            for resource in resources {
                resource.worker?.release()
            }
            while true {
                guard !cancelled() else { throw CancellationError() }
                refreshPressure()
                value = state(); value.pressure = max(value.pressure, pressureLock.withLock { pressure })
                if value.pressure >= 2 || value.thermal >= 2 {
                    constrainedUntil = clock() + policy.recovery
                } else if !value.paused, clock() >= constrainedUntil {
                    break
                }
                setWaiting(value.paused ? .priority : (value.pressure >= 2 ? .memory :
                        (value.thermal >= 2 ? .thermal : .recovery)))
                sleep(0.020)
            }
        } else {
            let slow = value.active || value.pressure > 0 || value.thermal > 0
            let quantum = slow ? policy.activeQuantum : policy.quantum
            if started - slice < quantum {
                return 0
            }
            let suspended = child?.suspend() ?? false
            defer {
                if suspended {
                    _ = child?.resume()
                }
            }
            let end = clock() + (slow ? policy.activeRest : policy.rest)
            while clock() < end {
                guard !cancelled() else { throw CancellationError() }
                sleep(min(0.010, max(0, end - clock())))
            }
        }
        slice = clock()
        let elapsed = slice - started
        statisticsLock.withLock {
            counters.yields += 1; counters.milliseconds += Int((elapsed * 1000).rounded())
        }
        return elapsed
    }
}
