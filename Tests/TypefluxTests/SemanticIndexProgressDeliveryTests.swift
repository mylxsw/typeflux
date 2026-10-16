import Foundation
import Testing
@testable import Typeflux

/// Holds main-actor deliveries without blocking a producer or depending on actor ordering.
final class SemanticProgressScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor @Sendable () -> Void] = []
    var count: Int { lock.withLock { pending.count } }
    func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) { lock.withLock { pending.append(action) } }
    @MainActor func run() {
        let action = lock.withLock { pending.removeFirst() }
        action()
    }
}

@Suite("Bounded semantic index progress", .serialized, .exclusiveUIState)
@MainActor
struct SemanticIndexProgressDeliveryTests {
    @Test func producerFloodKeepsOneDeliveryAndLatestAbsoluteSnapshotsIncludingNil() async {
        let queue = SemanticProgressScheduler(), source = SemanticIndexProgressDelivery.Source()
        let delivery = SemanticIndexProgressDelivery(schedule: { queue.enqueue($0) })
        var received: [SemanticIndexProgressDelivery.Snapshot] = []
        delivery.begin(source) { received.append($0) }
        await Task.detached {
            for index in 0..<100_000 {
                delivery.offer(.summary(.init(files: index, skipped: index / 2, processed: index, priorityUpdates: index)), from: source)
                delivery.offer(.path("synthetic-\(index)"), from: source)
                delivery.offer(.download(Double(index) / 100_000), from: source)
            }
            delivery.offer(.path(nil), from: source)
            delivery.offer(.download(nil), from: source)
        }.value
        #expect(queue.count == 1 && received.isEmpty)
        queue.run()
        #expect(queue.count == 0 && received.count == 1)
        #expect(received[0].summary?.files == 99_999 && received[0].summary?.skipped == 49_999)
        #expect(received[0].summary?.priorityUpdates == 99_999)
        #expect(received[0].hasPath && received[0].path == nil)
        #expect(received[0].hasDownload && received[0].download == nil)
        delivery.offer(.download(0.75), from: source)
        queue.run()
        #expect(received[1].download == 0.75 && !received[1].hasPath && received[1].summary == nil)
    }

    @Test func replacementAndFinishShareTheExistingQueuedSlotAndRejectLateSources() {
        let queue = SemanticProgressScheduler()
        let mailbox = SemanticIndexProgressDelivery(schedule: { queue.enqueue($0) })
        var received = 0
        let original = SemanticIndexProgressDelivery.Source()
        mailbox.begin(original) { _ in received += 1 }
        mailbox.offer(.path("old"), from: original)
        var latest = original
        for _ in 0..<1_000 {
            mailbox.invalidate()
            latest = SemanticIndexProgressDelivery.Source()
            mailbox.begin(latest) { _ in received += 1 }
            mailbox.offer(.path("new"), from: latest)
        }
        mailbox.offer(.summary(.init(files: 777)), from: original)
        #expect(mailbox.finish(original) == nil)
        #expect(queue.count == 1)
        let last = mailbox.finish(latest)
        #expect(last?.path == "new" && last?.summary == nil)
        mailbox.offer(.path("late"), from: latest)
        queue.run()
        #expect(received == 0 && queue.count == 0)
        #expect(mailbox.finish(latest) == nil)
    }

    @Test func offerDuringDeliverySchedulesOnlyOneFollowupAndCanBeSealedInsideSink() {
        let queue = SemanticProgressScheduler(), source = SemanticIndexProgressDelivery.Source()
        let delivery = SemanticIndexProgressDelivery(schedule: { queue.enqueue($0) })
        var values: [Int] = []
        delivery.begin(source) { snapshot in
            values.append(snapshot.summary!.files)
            if values.count == 1 {
                for index in 1...100 { delivery.offer(.summary(.init(files: index)), from: source) }
            } else {
                delivery.offer(.path(nil), from: source)
                #expect(delivery.finish(source)?.hasPath == true)
            }
        }
        delivery.offer(.summary(.init()), from: source)
        queue.run()
        #expect(queue.count == 1 && values == [0])
        queue.run()
        #expect(queue.count == 0 && values == [0, 100])
        delivery.invalidate()
    }

    @Test func finalSnapshotIsCollectedBeforeTerminalStateAndIdleMailboxCanRestart() {
        let queue = SemanticProgressScheduler(), delivery = SemanticIndexProgressDelivery(schedule: { queue.enqueue($0) })
        let source = SemanticIndexProgressDelivery.Source()
        var phase = "indexing"
        delivery.begin(source) { _ in phase = "indexing" }
        delivery.offer(.summary(.init(files: 12, skipped: 4, total: 16, processed: 16)), from: source)
        delivery.offer(.download(nil), from: source)
        let final = delivery.finish(source)
        phase = "ready"
        queue.run()
        #expect(phase == "ready" && final?.summary?.processed == 16 && final?.hasDownload == true)
        let next = SemanticIndexProgressDelivery.Source()
        delivery.begin(next) { _ in phase = "next" }
        delivery.offer(.path(nil), from: next)
        queue.run()
        #expect(phase == "next")
        delivery.invalidate()
        delivery.offer(.path("late"), from: next)
        #expect(queue.count == 0)
    }
}
