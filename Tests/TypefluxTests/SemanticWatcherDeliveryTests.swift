import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded semantic watcher handoff", .serialized, .exclusiveUIState)
@MainActor
struct SemanticWatcherDeliveryTests {
    private func source() -> SemanticWatcherDelivery.Source {
        .init(scope: semanticScope("/private/synthetic-watch"), indexDirectory: "/private/synthetic-index",
              lifecycle: AskSearchCancellation())
    }

    @Test func producerFloodUnionsObligationsAndHighestReceiptWithoutQueuingRawBatches() async {
        let source = source(), queue = SemanticProgressScheduler()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [SemanticWatcherDelivery.Snapshot] = []
        delivery.begin(source) { received.append($0) }
        await Task.detached {
            for index in 0..<100_000 {
                delivery.offer([.init(path: "/private/synthetic-watch/report.md", rescan: false)], eventID: UInt64(index), from: source)
            }
            delivery.offer([.init(path: "/private/synthetic-watch/other.pdf", rescan: false),
                            .init(path: "/private/synthetic-watch/folder/old.md", rescan: false, renamed: true)], eventID: 7, from: source)
            delivery.offer([.init(path: "/private/synthetic-watch/ignored.json", rescan: false)], eventID: 100_001, from: source)
        }.value
        #expect(queue.count == 1 && received.isEmpty)
        queue.run()
        #expect(received.count == 1 && received[0].eventID == 100_001)
        #expect(received[0].plan.files == ["/private/synthetic-watch/report.md", "/private/synthetic-watch/other.pdf"])
        #expect(received[0].plan.directories == ["/private/synthetic-watch/folder"] && !received[0].plan.fullScan)
        delivery.invalidate()
    }

    @Test func countAndByteOverflowKeepFullScanObligationAndReceipt() {
        let source = source(), queue = SemanticProgressScheduler()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [SemanticWatcherDelivery.Snapshot] = []
        delivery.begin(source) { received.append($0) }
        let changes = (0..<SemanticFileChangePlan.handoffPaths).map {
            AskFileChange(path: "/private/synthetic-watch/\($0).md", rescan: false)
        }
        delivery.offer(changes, eventID: 10, from: source)
        queue.run()
        #expect(received[0].plan.files.count == SemanticFileChangePlan.handoffPaths && !received[0].plan.fullScan)
        delivery.offer(changes, eventID: 11, from: source)
        delivery.offer([.init(path: "/private/synthetic-watch/overflow.md", rescan: false)], eventID: 12, from: source)
        queue.run()
        #expect(received[1].plan.fullScan && received[1].plan.files.isEmpty && received[1].eventID == 12)
        let oversized = "/private/synthetic-watch/" + String(repeating: "x", count: SemanticFileChangePlan.handoffBytes) + ".md"
        delivery.offer([.init(path: oversized, rescan: false)], eventID: 13, from: source)
        queue.run(); #expect(received[2].plan.fullScan && received[2].eventID == 13)
        // Full-scan semantics supersede targeted obligations, not their receipt.
        delivery.offer([.init(path: "/", rescan: true)], eventID: 14, from: source)
        delivery.offer(changes, eventID: 15, from: source)
        queue.run(); #expect(received[3].plan.fullScan && received[3].plan.directories.isEmpty && received[3].eventID == 15)
        delivery.invalidate()
    }

    @Test func replacementCancellationAndInvalidationShareOneQueuedSlot() {
        let queue = SemanticProgressScheduler(), old = source()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(old) { received.append($0.eventID) }
        delivery.offer([], eventID: 1, from: old)
        var current = old
        for index in 2...1_000 {
            delivery.invalidate(); current = source()
            delivery.begin(current) { received.append($0.eventID) }
            delivery.offer([], eventID: UInt64(index), from: current)
        }
        delivery.offer([], eventID: UInt64.max, from: old)
        #expect(queue.count == 1)
        queue.run(); #expect(received == [1_000])
        delivery.offer([], eventID: 1_001, from: current)
        current.lifecycle.cancel()
        delivery.offer([], eventID: 1_002, from: current)
        queue.run()
        #expect(queue.count == 0 && received == [1_000])
        delivery.invalidate()
    }

    @Test func offersDuringSinkUseOneSuccessorAndRevocationSealsIt() {
        let queue = SemanticProgressScheduler(), source = source()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(source) { snapshot in
            received.append(snapshot.eventID)
            for index in 2...100 { delivery.offer([], eventID: UInt64(index), from: source) }
            if received.count == 2 { delivery.invalidate() }
        }
        delivery.offer([], eventID: 1, from: source)
        queue.run(); #expect(queue.count == 1)
        queue.run(); #expect(queue.count == 0 && received == [1, 100])
    }
}
