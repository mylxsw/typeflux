import Foundation

enum ModuleState: String, Sendable, Codable {
    case stopped, starting, ready, recovering, circuitOpen, degraded, disabled
}

/// Content-free diagnostics. Never retain an underlying error's message here.
struct ModuleHealth: Sendable, Codable, Equatable {
    let state: ModuleState
    let generation: UUID
    let pendingStarts: Int
    let activeOperations: Int
    let hasLifecycleWork: Bool
    let failure: ModuleFailure?
}

enum ModuleFailure: Error, Equatable, Sendable, Codable {
    case unavailable, overloaded, disabled, invalidPolicy, quarantined, healthPersistence
    case startupTimeout, operationTimeout, cleanupTimeout, invalidated
}

enum ModuleFailureDisposition: Sendable {
    case operationOnly, recover, waitForExplicitRetry
}

enum ModuleRecoveryResponse: Sendable, Equatable, Codable {
    case ready, started, coolingDown, busy, disabled, cancelled, unavailable
}

struct ModulePolicy: Sendable {
    var startupTimeout: TimeInterval = 5
    var operationTimeout: TimeInterval = 15
    var cleanupTimeout: TimeInterval = 2
    var maxInFlight = 8
    var automaticallyRecover = true
    var automaticallyRecoverPersistentQuarantine = false

    var isValid: Bool {
        [startupTimeout, operationTimeout, cleanupTimeout].allSatisfy {
            $0.isFinite && $0 > 0 && $0 <= 86400
        } && (1...64).contains(maxInFlight)
    }
}

/// A synchronous admission fence also works during applicationWillTerminate,
/// when the application may not give an actor another turn before exiting.
final class ModuleAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    private var terminated = false
    private var dependencies: [ModuleHealthChannel] = []

    var permitsWork: Bool {
        let snapshot = lock.withLock { (enabled && !terminated, dependencies) }
        return snapshot.0 && snapshot.1.allSatisfy { $0.current?.state == .ready }
    }

    func require(_ dependencies: [ModuleHealthChannel]) {
        lock.withLock { self.dependencies = dependencies }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled && !terminated }
    }

    func shutdown() {
        lock.withLock { terminated = true; enabled = false }
    }
}
