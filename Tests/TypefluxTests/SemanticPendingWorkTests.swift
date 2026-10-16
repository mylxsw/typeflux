import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded semantic priority intents")
struct SemanticPendingWorkTests {
    @Test func standaloneTargetedAndScanWorkKeepTheirOriginalSemantics() {
        let gate = SemanticIndexPauseGate()
        #expect(!gate.enqueueDocuments(["/synthetic/b.md", "/synthetic/a.md", "/synthetic/a.md"]))
        gate.enqueueDocumentScan()
        let work = gate.takeDocuments()
        #expect(work.paths == ["/synthetic/a.md", "/synthetic/b.md"] && work.scan && !work.overflowed)
        #expect(gate.takeDocuments().paths.isEmpty && !gate.takeDocuments().scan)
        gate.setPaused(true); #expect(gate.isPaused)
        gate.setPaused(false); #expect(!gate.isPaused)
    }

    @Test func floodAndByteOverflowRemainBoundedAndRequireOwningCatchup() async {
        let gate = SemanticIndexPauseGate(), lifecycle = AskSearchCancellation()
        let source = SemanticIndexPauseGate.Source(lifecycle: lifecycle)
        gate.begin(source)
        let overflowed = await Task.detached {
            var overflowed = false
            for index in 0..<100_000 {
                overflowed = gate.enqueueDocuments(["/synthetic/\(index).md"], from: source) || overflowed
            }
            return overflowed
        }.value
        #expect(overflowed)
        let work = gate.takeDocuments(from: source)
        #expect(work.scan && work.overflowed && work.paths.isEmpty)
        #expect(!gate.takeDocuments(from: source).scan)
        let long = "/synthetic/" + String(repeating: "x", count: SemanticFileChangePlan.handoffBytes) + ".md"
        #expect(gate.enqueueDocuments([long], from: source))
        #expect(gate.takeDocuments(from: source).overflowed)
    }

    @Test func oldWorkerCannotTakeReplacementWorkAndBindingDoesNotFreeActualQueryOccupancy() {
        let gate = SemanticIndexPauseGate()
        let old = SemanticIndexPauseGate.Source(lifecycle: AskSearchCancellation())
        let current = SemanticIndexPauseGate.Source(lifecycle: AskSearchCancellation())
        gate.begin(old)
        gate.beginQuery(); gate.beginQuery()
        #expect(!gate.enqueueDocuments(["/synthetic/old.md"], from: old))
        old.lifecycle.cancel(); gate.begin(current)
        #expect(gate.isPaused)
        #expect(!gate.enqueueDocuments(["/synthetic/current.md"], from: current))
        #expect(gate.takeDocuments(from: old).paths.isEmpty)
        #expect(gate.takeDocuments().paths.isEmpty, "standalone callers cannot drain an owned service source")
        #expect(!gate.enqueueDocuments(["/synthetic/stale.md"], from: old))
        gate.enqueueDocumentScan() // Standalone scan admission is also isolated.
        let work = gate.takeDocuments(from: current)
        #expect(work.paths == ["/synthetic/current.md"] && !work.scan)
        gate.invalidate()
        #expect(!gate.enqueueDocuments(["/synthetic/late.md"], from: current))
        #expect(gate.takeDocuments(from: current).paths.isEmpty && gate.isPaused)
        gate.endQuery(); #expect(gate.isPaused)
        gate.endQuery(); gate.endQuery(); #expect(!gate.isPaused)
        gate.begin(current)
        #expect(!gate.enqueueDocuments(["/synthetic/revoked.md"], from: current))
        current.lifecycle.cancel()
        #expect(gate.takeDocuments(from: current).paths.isEmpty)
    }
}
