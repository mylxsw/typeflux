import Foundation
import TypefluxInferenceProtocol

/// Independent inference admission. Preparation and the selected model may each
/// own one child; a timed-out child remains counted until confirmed retirement.
final class WhisperWorkerPool: @unchecked Sendable {
    static let shared = WhisperWorkerPool()
    private let lock = NSLock()
    private var entries: [UUID: (paths: [String], stop: @Sendable () -> Void)] = [:]
    private var disabled = false
    private var budget = ModuleRecoveryBudget()
    private let uptime: @Sendable () -> TimeInterval

    init(uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
    }

    func reserve(paths: [String], stop: @escaping @Sendable () -> Void) throws -> UUID {
        try lock.withLock {
            guard !disabled, budget.permitsAttempt(at: uptime()) else { throw InferenceFailure.unavailable }
            guard entries.count < 2 else { throw InferenceFailure.busy }
            let id = UUID()
            entries[id] = (paths, stop)
            return id
        }
    }

    func release(_ id: UUID, failed: Bool) {
        lock.withLock {
            guard entries.removeValue(forKey: id) != nil else { return }
            if failed { budget.failed(at: uptime()) }
        }
    }

    func recordFailure() { lock.withLock { budget.failed(at: uptime()) } }

    func checkUnused(_ directory: URL) throws {
        let path = directory.standardizedFileURL.path
        try lock.withLock {
            guard !entries.values.contains(where: { entry in
                entry.paths.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
            }) else { throw InferenceFailure.busy }
        }
    }

    func preventNewWork() {
        let stops = lock.withLock {
            disabled = true
            return entries.values.map(\.stop)
        }
        stops.forEach { $0() }
    }

    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while lock.withLock({ !entries.isEmpty }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
        }
    }

    var activeCount: Int { lock.withLock { entries.count } }
}

/// Factory cancellation is synchronous, including while model loading is pending.
final class WhisperWorkerOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var client: WhisperWorkerClient?
    var permitsWork: Bool { lock.withLock { !stopped } }
    func install(_ client: WhisperWorkerClient) throws {
        try lock.withLock {
            guard !stopped else { client.stop(); throw InferenceFailure.cancelled }
            self.client = client
        }
    }
    func stop() {
        let client = lock.withLock { stopped = true; return self.client }
        client?.stop()
    }
}
