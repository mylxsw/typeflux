import Foundation
import XCTest
@testable import Typeflux

final class MainThreadHangMonitorTests: XCTestCase {
    func testOneOutstandingProbeAndOneReportPerStall() {
        var heartbeat = MainThreadHeartbeat()
        XCTAssertEqual(heartbeat.tick(at: 0), .probe(1))
        for time in [0.25, 0.5, 1, 1.75] { XCTAssertNil(heartbeat.tick(at: time)) }
        XCTAssertEqual(heartbeat.tick(at: 2), .stalled(2))
        XCTAssertNil(heartbeat.tick(at: 3))
        XCTAssertNil(heartbeat.acknowledge(9, at: 3))
        XCTAssertEqual(heartbeat.acknowledge(1, at: 3.5), .recovered(3.5))
        XCTAssertEqual(heartbeat.tick(at: 4), .probe(2))
    }

    func testHealthyRepliesAndSleepDoNotReportHangs() {
        var heartbeat = MainThreadHeartbeat()
        XCTAssertEqual(heartbeat.tick(at: 0), .probe(1))
        XCTAssertNil(heartbeat.acknowledge(1, at: 0.1))
        XCTAssertEqual(heartbeat.tick(at: 0.25), .probe(2))
        XCTAssertEqual(heartbeat.tick(at: 100), .probe(3))
        XCTAssertNil(heartbeat.acknowledge(2, at: 100.1))
        XCTAssertNil(heartbeat.tick(at: 100.25))
        XCTAssertNil(heartbeat.acknowledge(3, at: 100.3))
        XCTAssertEqual(heartbeat.tick(at: 101), .probe(4))
        XCTAssertEqual(heartbeat.tick(at: 1), .probe(5))
    }

    func testMonitorReportsWithoutWaitingForTheMainQueue() async {
        let stalled = expectation(description: "independent watchdog")
        let monitor = MainThreadHangMonitor(report: { event in
            if case .stalled = event { stalled.fulfill() }
        }, scheduleProbe: { _ in /* Simulate a main queue which never answers. */ })
        monitor.start()
        monitor.start()
        await fulfillment(of: [stalled], timeout: 4)
        monitor.stop()
    }

    func testLateMainQueueAcknowledgementReportsRecovery() async {
        let state = ProbeState()
        let scheduled = expectation(description: "probe scheduled")
        let stalled = expectation(description: "stall")
        let recovered = expectation(description: "recovery")
        let monitor = MainThreadHangMonitor(report: { event in
            switch event {
            case .stalled: stalled.fulfill()
            case let .recovered(seconds): XCTAssertEqual(seconds, 4); recovered.fulfill()
            case .probe: XCTFail("Probes are not diagnostic reports")
            }
        }, scheduleProbe: { callback in
            let first = state.lock.withLock {
                guard state.callback == nil else { return false }
                state.callback = callback; return true
            }
            if first { scheduled.fulfill() }
        }, now: { state.lock.withLock { state.time } })
        monitor.start()
        await fulfillment(of: [scheduled], timeout: 1)
        state.lock.withLock { state.time = 3 }
        await fulfillment(of: [stalled], timeout: 1)
        let callback = state.lock.withLock { state.time = 4; return state.callback }
        callback?()
        await fulfillment(of: [recovered], timeout: 1)
        monitor.stop()
    }

    func testDiagnosticsRetainsFivePrivateReportsAndCoalescesRepeatedIncidents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<7 {
            try Data("old".utf8).write(to: directory.appendingPathComponent("main-0\(index).txt"))
        }
        let sampled = expectation(description: "sample written")
        sampled.assertForOverFulfill = true
        let diagnostics = MainThreadHangDiagnostics(directory: directory, now: { 10 }, capture: { request in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(request.executable, "/usr/bin/sample")
            XCTAssertEqual(request.timeout, 5)
            XCTAssertEqual(request.outputLimit, 2 * 1024 * 1024)
            XCTAssertTrue(request.stopOnOutputLimit)
            XCTAssertEqual(request.environment, ["PATH": "/usr/bin:/bin"])
            return .init(termination: .exited(0), exitCode: 0, stdout: "Call graph: test sample", stderr: "", outputTruncated: false)
        }, sampleFinished: { sampled.fulfill() })
        diagnostics.record(.probe(1))
        for _ in 0..<20 { diagnostics.record(.stalled(2)) }
        await fulfillment(of: [sampled], timeout: 2)
        diagnostics.record(.stalled(3)) // Still inside the cooldown, even after the worker has drained.
        diagnostics.record(.recovered(4))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
        let report = try XCTUnwrap(files.first { $0.lastPathComponent.count > 20 })
        XCTAssertEqual(try String(contentsOf: report, encoding: .utf8), "Call graph: test sample")
        let attributes = try FileManager.default.attributesOfItem(atPath: report.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDiagnosticCaptureFailureDoesNotLeaveAPartialReportOrBlockRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let completed = expectation(description: "failed capture retired")
        let diagnostics = MainThreadHangDiagnostics(directory: directory, capture: { _ in
            throw CocoaError(.fileWriteNoPermission)
        }, sampleFinished: { completed.fulfill() })
        diagnostics.record(.stalled(2))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        diagnostics.record(.recovered(3))
    }
}

private final class ProbeState: @unchecked Sendable {
    let lock = NSLock()
    var time: TimeInterval = 0
    var callback: (@Sendable () -> Void)?
}
