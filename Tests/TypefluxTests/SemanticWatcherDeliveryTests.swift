import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded semantic watcher handoff", .serialized, .exclusiveUIState)
@MainActor
struct SemanticWatcherDeliveryTests {
    private func source() -> SemanticWatcherDelivery.Source {
        .init(lifecycle: AskSearchCancellation())
    }

    @Test func producerFloodDeliversOnlyTheHighestEventID() async {
        let source = source(), queue = SemanticProgressScheduler()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(source) { received.append($0) }
        await Task.detached {
            for index in 0..<100_000 {
                delivery.offer(eventID: UInt64(index), from: source)
            }
            delivery.offer(eventID: 100_001, from: source)
            delivery.offer(eventID: 7, from: source)
        }.value
        #expect(queue.count == 1 && received.isEmpty)
        queue.run()
        #expect(received == [100_001])
        delivery.invalidate()
    }

    @Test func eachDeliveryClearsItsPendingEventID() {
        let source = source(), queue = SemanticProgressScheduler()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(source) { received.append($0) }
        delivery.offer(eventID: 10, from: source)
        queue.run()
        delivery.offer(eventID: 0, from: source)
        queue.run()
        #expect(received == [10, 0] && queue.count == 0)
        delivery.invalidate()
    }

    @Test func replacementCancellationAndInvalidationShareOneQueuedSlot() {
        let queue = SemanticProgressScheduler(), old = source()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(old) { received.append($0) }
        delivery.offer(eventID: 1, from: old)
        var current = old
        for index in 2...1_000 {
            delivery.invalidate(); current = source()
            delivery.begin(current) { received.append($0) }
            delivery.offer(eventID: UInt64(index), from: current)
        }
        delivery.offer(eventID: UInt64.max, from: old)
        #expect(queue.count == 1)
        queue.run(); #expect(received == [1_000])
        delivery.offer(eventID: 1_001, from: current)
        current.lifecycle.cancel()
        delivery.offer(eventID: 1_002, from: current)
        queue.run()
        #expect(queue.count == 0 && received == [1_000])
        delivery.invalidate()
    }

    @Test func offersDuringSinkUseOneSuccessorAndRevocationSealsIt() {
        let queue = SemanticProgressScheduler(), source = source()
        let delivery = SemanticWatcherDelivery(schedule: { queue.enqueue($0) })
        var received: [UInt64] = []
        delivery.begin(source) { eventID in
            received.append(eventID)
            for index in 2...100 { delivery.offer(eventID: UInt64(index), from: source) }
            if received.count == 2 { delivery.invalidate() }
        }
        delivery.offer(eventID: 1, from: source)
        queue.run(); #expect(queue.count == 1)
        queue.run(); #expect(queue.count == 0 && received == [1, 100])
    }
}
