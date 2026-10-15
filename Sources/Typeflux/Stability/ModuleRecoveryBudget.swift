import Foundation

/// Admission for rebuilding a failed service. It never authorizes replaying an
/// operation. The owner serializes access and supplies a monotonic clock.
struct ModuleRecoveryBudget {
    enum State: Equatable {
        case available
        case waiting(until: TimeInterval)
        case circuitOpen(until: TimeInterval)
    }

    private(set) var state: State = .available
    private var failures: [TimeInterval] = []
    private var healthySince: TimeInterval?

    func permitsAttempt(at now: TimeInterval) -> Bool {
        switch state {
        case .available: true
        case let .waiting(until), let .circuitOpen(until): now >= until
        }
    }

    mutating func failed(at now: TimeInterval) {
        healthySince = nil
        if case .circuitOpen = state {
            state = .circuitOpen(until: now + 300)
            return
        }
        failures.removeAll { now - $0 >= 60 }
        failures.append(now)
        if failures.count > 3 {
            state = .circuitOpen(until: now + 300)
        } else {
            state = .waiting(until: now + pow(2, Double(failures.count - 1)))
        }
    }

    mutating func succeeded(at now: TimeInterval) {
        state = .available
        if let healthySince, now - healthySince >= 600 {
            failures = []
        } else if healthySince == nil {
            healthySince = now
        }
    }
}
