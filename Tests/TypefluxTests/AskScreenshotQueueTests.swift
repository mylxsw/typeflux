import Foundation
import Testing
@testable import Typeflux

@Suite("Bounded context screenshot queue", .exclusiveUIState)
@MainActor
struct AskScreenshotQueueTests {
    private final class NativeCapture {
        var started = false
        var finished = false
        var continuation: CheckedContinuation<String, Never>?
        func capture() async -> String {
            started = true
            let value = await withCheckedContinuation { continuation = $0 }
            finished = true
            return value
        }
        func complete() { continuation?.resume(returning: "old-image"); continuation = nil }
    }

    @Test func cancellationReleasesCallerButKeepsNativeSlotUntilCallback() async throws {
        let queue = ScreenshotTaskQueue<String>(), native = NativeCapture()
        var cancelled = false, nextStarted = false
        let first = Task {
            do { _ = try await queue.capture { await native.capture() }; Issue.record("Cancelled capture returned an image") }
            catch is CancellationError { cancelled = true }
            catch { Issue.record(error) }
        }
        try await wait { native.started }
        first.cancel()
        try await wait { cancelled }
        #expect(!native.finished)
        let next = Task { try await queue.capture { nextStarted = true; return "new-image" } }
        // The queued span is observable before the system callback is released.
        await Task.yield()
        #expect(!nextStarted)
        native.complete()
        #expect(try await next.value == "new-image")
        await first.value
        #expect(native.finished)
    }

    @Test func burstKeepsOnlyNewestPendingCaptureAndPreservesItsTrace() async throws {
        let queue = ScreenshotTaskQueue<String>(), native = NativeCapture()
        let collector = ShortcutLatencyEventCollector()
        let firstTrace = diagnosticTestTrace(.launcher)
        let latestTrace = diagnosticTestTrace(.launcher)
        var starts: [Int] = []
        var tasks: [Task<String?, Never>] = []
        await ShortcutLatency.$eventSink.withValue(collector.sink) {
            let first = Task {
                try? await ShortcutLatency.$current.withValue(firstTrace) {
                    try await queue.capture { await native.capture() }
                }
            }
            tasks.append(first)
            do { try await wait { native.started } } catch { Issue.record(error); return }
            for index in 1...20 {
                let task = Task {
                    try? await ShortcutLatency.$current.withValue(latestTrace) {
                        try await queue.capture { starts.append(index); return "image-\(index)" }
                    }
                }
                tasks.append(task)
                do { try await wait { collector.stages.filter { $0 == .captureQueued }.count == index + 1 } }
                catch { Issue.record(error); break }
            }
        }
        #expect(starts.isEmpty)
        native.complete()
        var results: [String?] = []
        for task in tasks { results.append(await task.value) }
        #expect(results.dropLast().allSatisfy { $0 == nil })
        #expect(results.last == "image-20")
        #expect(starts == [20])
        let dequeued = collector.events.filter { $0.stage == .captureDequeued }
        #expect(dequeued.map(\.trace) == [firstTrace, latestTrace])
        #expect(collector.events.filter { $0.stage == .captureSuperseded }.count == 20)
        #expect(collector.events.filter { $0.stage == .captureDiscarded }.map(\.trace) == [firstTrace])
    }

    @Test func cancelledPendingCaptureNeverReachesNativeAPI() async throws {
        let queue = ScreenshotTaskQueue<String>(), native = NativeCapture()
        let collector = ShortcutLatencyEventCollector()
        let active = Task { try? await queue.capture { await native.capture() } }
        try await wait { native.started }
        var pendingCancelled = false
        let pending = Task {
            await ShortcutLatency.$eventSink.withValue(collector.sink) {
                await ShortcutLatency.$current.withValue(diagnosticTestTrace(.launcher)) {
                    do { _ = try await queue.capture { Issue.record("Cancelled pending work ran"); return "image" } }
                    catch is CancellationError { pendingCancelled = true }
                    catch { Issue.record(error) }
                }
            }
        }
        try await wait { collector.stages.contains(.captureQueued) }
        pending.cancel()
        try await wait { pendingCancelled }
        native.complete()
        _ = await active.value
        await pending.value
        #expect(!collector.stages.contains(.captureDequeued))
        #expect(try await queue.capture { "after-cancellation" } == "after-cancellation")
    }

    @Test func failureReleasesSlotAndPrecancelledRequestsDoNotStart() async throws {
        enum Failure: Error { case fixture }
        let queue = ScreenshotTaskQueue<String>()
        await #expect(throws: Failure.self) { try await queue.capture { throw Failure.fixture } }
        #expect(try await queue.capture { "recovered" } == "recovered")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await queue.capture { Issue.record("Precancelled request started"); return "image" }
            }
        }
        await task.value
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitTimeout() }
            await Task.yield()
        }
    }
    private struct WaitTimeout: Error {}
}
