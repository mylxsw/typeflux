import Foundation
import Testing
@testable import Typeflux

@Suite("Trusted observation store", .exclusiveUIState)
@MainActor
struct AskObservationStoreTests {
    let scope = AskObservationStore.Scope(owner: "owner", conversation: "c", tool: "browser")
    let target = AskExecutionTarget(kind: "browser_tab", id: "browser", version: "process/window/tab/document")

    @Test func `expires consumes and does not trust I ds from another scope`() throws {
        var uptime = 10.0
        let store = AskObservationStore(lifetime: 2, now: { uptime }, date: { Date(timeIntervalSince1970: 123) })
        let first = store.record(.init(id: "untrusted", target: target, capturedAt: .distantPast), scope: scope)
        #expect(first.id != "untrusted"); #expect(first.capturedAt == Date(timeIntervalSince1970: 123))
        #expect(try store.validate(id: first.id, scope: scope, target: target) == first)
        for other in [AskObservationStore.Scope(owner: "other", conversation: "c", tool: "browser"),
                      .init(owner: "owner", conversation: "other", tool: "browser"), .init(
                          owner: "owner",
                          conversation: "c",
                          tool: "computer"
                      )] {
            #expect(throws: AskObservationError.needsObservation) { try store.validate(
                id: first.id,
                scope: other,
                target: target
            ) }
        }
        #expect(throws: AskObservationError.needsObservation) {
            try store.validate(id: nil, scope: scope, target: target)
        }
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: "forged",
            scope: scope,
            target: target
        ) }
        var changed = target; changed.version = "new document"
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: first.id,
            scope: scope,
            target: changed
        ) }
        uptime = 12
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: first.id,
            scope: scope,
            target: target
        ) }
        let second = store.record(first, scope: scope)
        #expect(AskObservationStore.boundTarget(second) != AskObservationStore.boundTarget(first))
        #expect(try store.consume(id: second.id, scope: scope, target: target) == second)
        #expect(throws: AskObservationError.needsObservation) { try store.consume(
            id: second.id,
            scope: scope,
            target: target
        ) }
        let third = store.record(first, scope: scope)
        store.invalidate(scope: scope)
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: third.id,
            scope: scope,
            target: target
        ) }
    }

    @Test func `replaces previous observation and bounds abandoned conversations`() {
        let store = AskObservationStore()
        let first = store.record(.init(id: "", target: target, capturedAt: Date()), scope: scope)
        _ = store.record(first, scope: scope)
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: first.id,
            scope: scope,
            target: target
        ) }
        for index in 0 ... 256 {
            _ = store.record(
                first,
                scope: .init(owner: "o", conversation: String(index), tool: "browser")
            )
        }
        #expect(throws: AskObservationError.needsObservation) { try store.validate(
            id: first.id,
            scope: scope,
            target: target
        ) }
    }

    @Test func `legacy projection preserves unknown and evidence`() {
        let output = AskActionReceipt(
            outcome: .init(status: "unknown", eventDispatched: true, effectVerified: false),
            message: "Reconcile"
        ).output()
        #expect(output.isError)
        #expect(output.content.contains("\"event_dispatched\":true"))
        #expect(output.content.contains("\"effect_verified\":false"))
        let large = AskActionReceipt.observed(String(repeating: "\\\"\n", count: 60000), reference: nil).output()
        #expect(large.content.count <= 60000)
        #expect(large.content.contains("\"truncated\":true"))
        for error in [AskObservationError.invalid, .disabled, .needsObservation] {
            #expect(!error.localizedDescription.isEmpty)
        }
        for error in [AskAutomationError.timeout, .unavailable] {
            #expect(!error.localizedDescription.isEmpty)
        }
    }
}
