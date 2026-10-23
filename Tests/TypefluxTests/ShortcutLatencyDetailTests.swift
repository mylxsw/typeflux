import Foundation
import Testing
@testable import Typeflux

final class ShortcutLatencyEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ShortcutLatencyEvent] = []
    func append(_ event: ShortcutLatencyEvent) {
        lock.withLock { storage.append(event) }
    }

    var sink: @Sendable (ShortcutLatencyEvent) -> Void { { self.append($0) } }

    var events: [ShortcutLatencyEvent] {
        lock.withLock { storage }
    }

    var stages: [ShortcutLatencyStage] {
        events.map(\.stage)
    }
}

func diagnosticTestTrace(_ feature: FeatureRole) -> ShortcutLatencyTrace {
    .init(id: UUID(), feature: feature, date: Date(), uptime: ProcessInfo.processInfo.systemUptime)
}

@Suite("Detailed shortcut diagnostics", .serialized, .exclusiveUIState)
struct ShortcutLatencyDetailTests {
    @Test func `spans preserve results errors and display ordinals`() {
        enum Failure: Error { case fixture }
        let collector = ShortcutLatencyEventCollector(), trace = diagnosticTestTrace(.screenshot)
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.$current.withValue(trace) {
                let value = ShortcutLatency.measure(
                    .displayViewStarted,
                    .displayViewFinished,
                    itemIndex: 2,
                    itemCount: 3
                ) { 42 }
                #expect(value == 42)
                #expect(throws: Failure.self) {
                    try ShortcutLatency.measure(.displayPanelStarted, .displayPanelFinished) { throw Failure.fixture }
                }
            }
        }
        #expect(collector.stages == [
            .displayViewStarted,
            .displayViewFinished,
            .displayPanelStarted,
            .displayPanelFinished
        ])
        #expect(collector.events.allSatisfy { $0.version == 2 && $0.trace == trace })
        #expect(collector.events.prefix(2).allSatisfy { $0.itemIndex == 2 && $0.itemCount == 3 })
        #expect(collector.events.suffix(2).allSatisfy { $0.itemIndex == nil && $0.itemCount == nil })
        #expect(collector.events.map(\.uptime) == collector.events.map(\.uptime).sorted())
    }

    @Test @MainActor func `visibility checks keep correlation across queue turns without leaking`() async {
        let collector = ShortcutLatencyEventCollector(), trace = diagnosticTestTrace(.ring)
        var visible = true
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.$current.withValue(trace) {
                ShortcutLatency.presentationOrdered { visible }
            }
        }
        #expect(ShortcutLatency.current == nil)
        #expect(collector.stages == [.windowOrdered])
        await drainMainQueue()
        #expect(collector.stages == [.windowOrdered, .visibleNextTurn])
        ShortcutLatency.$eventSink.withValue(collector.sink) {
            ShortcutLatency.presentationOrdered(trace: trace) { visible }
            visible = false
        }
        await drainMainQueue()
        #expect(collector.stages.suffix(2) == [.windowOrdered, .superseded])
        #expect(collector.events.allSatisfy { $0.trace == trace })
        #expect(ShortcutLatency.current == nil)
    }

    @Test func `legacy handlers remain unmeasured and new handlers require visibility`() {
        for feature in [FeatureRole.ring, .translation] {
            let trace = diagnosticTestTrace(feature)
            var event = ShortcutLatencyEvent(trace: trace, stage: .handlerFinished, uptime: trace.uptime + 1,
                                             pid: 1, role: feature, build: "fixture")
            #expect(ShortcutLatencyReport(events: [event]).samples[0].outcome == "handled")
            event.version = 2
            #expect(ShortcutLatencyReport(events: [event]).samples[0].outcome == "incomplete")
            #expect(ShortcutLatencyReport(events: [event]).summaries.allSatisfy { $0.p95Milliseconds == nil })
            let visible = ShortcutLatencyEvent(version: 2, trace: trace, stage: .visibleNextTurn,
                                               uptime: trace.uptime + 0.125, pid: 1, role: feature, build: "fixture")
            let report = ShortcutLatencyReport(events: [event, visible])
            #expect(report.samples[0].outcome == "visible")
            #expect(report.summaries.first?.p95Milliseconds == 125)
        }
    }

    @Test func `reader accepts both schemas and retains only safe optional metadata`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ShortcutLatencyWriter(directory: directory), trace = diagnosticTestTrace(.screenshot)
        let old = ShortcutLatencyEvent(
            trace: trace,
            stage: .recognized,
            uptime: trace.uptime,
            pid: 1,
            role: .host,
            build: "fixture"
        )
        let new = ShortcutLatencyEvent(
            version: 2,
            trace: trace,
            stage: .displayViewFinished,
            uptime: trace.uptime + 0.1,
            pid: 2,
            role: .screenshot,
            build: "fixture",
            itemIndex: 1,
            itemCount: 2
        )
        writer.record(old); writer.record(new)
        await writer.flush()
        let report = try ShortcutLatencyReport.read(directory: directory)
        #expect(report.invalidLines == 0 && report.samples.count == 1)
        #expect(report.samples[0].events.map(\.version) == [1, 2])
        #expect(report.samples[0].events.last?.itemIndex == 1)
        let decoded = try JSONDecoder().decode(ShortcutLatencyReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.samples[0].events.last?.itemCount == 2)
    }
}

@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}
