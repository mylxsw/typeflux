import Foundation
import Testing
@testable import Typeflux

private final class BudgetReasonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SemanticWorkBudget.Waiting?] = []
    func append(_ value: SemanticWorkBudget.Waiting?) {
        lock.withLock { stored.append(value) }
    }

    var values: [SemanticWorkBudget.Waiting?] {
        lock.withLock { stored }
    }
}

@Suite("Background compute budget", .serialized)
struct SemanticWorkBudgetTests {
    @Test func `ordinary activity slows work without stopping useful progress`() throws {
        var now: Double = 0
        var state = SemanticWorkBudget.State()
        let budget = SemanticWorkBudget(enabled: true, state: { state }, clock: { now }, sleep: { now += $0 })
        #expect(try budget.checkpoint(cancelled: { false }) == 0)
        now = 0.05
        let idle = try budget.checkpoint(cancelled: { false })
        #expect(abs(idle - 0.04) < 1e-9)
        state.active = true; now += 0.02
        let active = try budget.checkpoint(cancelled: { false })
        #expect(abs(active - 0.09) < 1e-9)
        #expect(budget.statistics.yields == 2 && abs(budget.statistics.milliseconds - 130) <= 1)
        #expect(throws: CancellationError.self) { try budget.checkpoint(cancelled: { true }) }
    }

    @Test func `pressure interrupts an inference and recovery has hysteresis`() throws {
        var now: Double = 0
        var state = SemanticWorkBudget.State(pressure: 2)
        let budget = SemanticWorkBudget(enabled: true, state: { state }, clock: { now }, sleep: {
            now += $0
            if now >= 0.1 {
                state.pressure = 0
            }
        })
        #expect(throws: SemanticWorkBudget.Interrupted.self) { try budget.checkpoint(
            child: Process(),
            cancelled: { false }
        ) }
        let waited = try budget.checkpoint(cancelled: { false })
        #expect(waited >= 5 && waited < 5.2)
        #expect(budget.statistics.interruptions == 1)
        state.paused = true
        #expect(throws: SemanticWorkBudget.Interrupted.self) { try budget.checkpoint(
            child: Process(),
            cancelled: { false }
        ) }
        state.paused = false
        #expect(try budget.checkpoint(cancelled: { false }) < 0.1, "query priority does not impose a pressure cooldown")
    }

    @Test func waitingReasonTracksPriorityMemoryThermalAndRecoveryTransitions() throws {
        var now: Double = 0, tick = 0
        var state = SemanticWorkBudget.State(paused: true), policy = SemanticWorkBudget.Policy()
        policy.recovery = 0.04
        let reasons = BudgetReasonRecorder()
        let budget = SemanticWorkBudget(
            policy: policy,
            enabled: true,
            state: { state },
            onWaiting: { reasons.append($0) },
            clock: { now },
            sleep: {
                now += $0; tick += 1
                state = tick == 1 ? .init(pressure: 2) : (tick == 2 ? .init(thermal: 2) : .init())
            }
        )
        _ = try budget.checkpoint(cancelled: { false })
        #expect(reasons.values == [.priority, .memory, .thermal, .recovery, nil])
    }

    @Test func `task-local budget also interrupts long database writes`() throws {
        let root = try semanticFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SemanticFileStore(url: root.appendingPathComponent("index.sqlite"))
        let token = AskSearchCancellation()
        let budget = SemanticWorkBudget(enabled: true, state: { .init() })
        #expect(throws: SemanticFileStore.Failure.self) {
            try budget.perform(cancelled: { token.isCancelled }) {
                token.cancel()
                try store.lock.withLock {
                    try store
                        .sql(
                            "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<100000) SELECT sum(x) FROM n"
                        )
                }
            }
        }
        #expect(SemanticWorkBudget.current == nil && SemanticWorkBudget.cancellation == nil)
    }

    @Test func `cancellation breaks pressure waits and disabled budget remains transparent`() throws {
        var now: Double = 0
        let budget = SemanticWorkBudget(
            enabled: true,
            state: { .init(thermal: 3) },
            clock: { now },
            sleep: { now += $0 }
        )
        #expect(throws: CancellationError.self) { try budget.checkpoint(cancelled: { now >= 0.04 }) }
        let off = SemanticWorkBudget(enabled: false, state: { .init(pressure: 2) })
        #expect(try off.checkpoint(cancelled: { false }) == 0)
        #expect(off.statistics == .init())
    }
}
