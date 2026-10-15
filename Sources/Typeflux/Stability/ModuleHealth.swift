import Foundation

enum ModuleState: String, Sendable {
    case stopped, starting, ready, recovering, circuitOpen, degraded, disabled
}

/// Content-free diagnostics. Never retain an underlying error's message here.
struct ModuleHealth: Sendable {
    let state: ModuleState
    let generation: UUID
    let pendingStarts: Int
    let activeOperations: Int
    let hasLifecycleWork: Bool
    let failure: ModuleFailure?
}

enum ModuleFailure: Error, Equatable, Sendable {
    case unavailable, overloaded, disabled, invalidPolicy
    case startupTimeout, operationTimeout, cleanupTimeout, invalidated
}

enum ModuleFailureDisposition: Sendable {
    case operationOnly, recover, waitForExplicitRetry
}

struct ModulePolicy: Sendable {
    var startupTimeout: TimeInterval = 5
    var operationTimeout: TimeInterval = 15
    var cleanupTimeout: TimeInterval = 2
    var maxInFlight = 8
    var automaticallyRecover = true

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

    var permitsWork: Bool { lock.withLock { enabled && !terminated } }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled && !terminated }
    }

    func shutdown() {
        lock.withLock { terminated = true; enabled = false }
    }
}
