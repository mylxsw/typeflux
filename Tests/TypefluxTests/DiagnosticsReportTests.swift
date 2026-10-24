import Foundation
import Testing
@testable import Typeflux

@Suite("Unified diagnostics", .exclusiveUIState)
@MainActor
struct DiagnosticsReportTests {
    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    @Test func `filters before sample cap and keeps whole trace at inclusive boundaries`() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let start = Date(timeIntervalSince1970: 1000)
        var data = Data()
        for index in 0 ..< 250 {
            let trace = ShortcutLatencyTrace(id: UUID(), feature: .launcher,
                                             date: start.addingTimeInterval(Double(index)), uptime: 100)
            for stage in [ShortcutLatencyStage.recognized, .visibleNextTurn] {
                let event = ShortcutLatencyEvent(trace: trace, stage: stage,
                                                 uptime: stage == .recognized ? 100 : 102, pid: 1, role: .host,
                                                 build: "fixture")
                try data.append(encoder.encode(event)); data.append(10)
            }
        }
        try data.write(to: folder.appendingPathComponent("events-fixture.jsonl"))
        let report = try ShortcutLatencyReport.read(directory: folder, interval: .init(start: start, duration: 1))
        #expect(report.samples.count == 2)
        #expect(report.samples.allSatisfy { $0.events.count == 2 && $0.visibleMilliseconds == 2000 })
        #expect(report.droppedEvents == 0)
    }

    @Test func `explains rejected records and preserves reasons when filtering`() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let trace = ShortcutLatencyTrace(id: UUID(), feature: .launcher, date: Date(), uptime: 100)
        var data = Data("broken\n".utf8)
        for (version, uptime) in [(3, 100.0), (2, 99.0), (2, 401.0)] {
            var event = ShortcutLatencyEvent(
                trace: trace,
                stage: .recognized,
                uptime: uptime,
                pid: 1,
                role: .host,
                build: "fixture"
            )
            event.version = version
            try data.append(encoder.encode(event)); data.append(10)
        }
        try data.write(to: folder.appendingPathComponent("events-fixture.jsonl"))
        let report = try ShortcutLatencyReport.read(directory: folder)
        #expect(report.invalidLines == 4)
        #expect(report.rejectedRecords?["traceOlderThanFiveMinutes"] == 1)
        #expect(report.rejectedRecords?["unsupportedVersion"] == 1)
        #expect(report.rejectedRecords?["invalidClock"] == 1)
        #expect(report.selecting(feature: "all", temperature: "all").rejectedRecords == report.rejectedRecords)
    }

    @Test func `reads only hang metadata and respects time range`() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        for index in 0 ..< 8 {
            try Data("PRIVATE STACK PAYLOAD".utf8)
                .write(to: folder.appendingPathComponent("main-\(1000 + index)-fixture.txt"))
        }
        try Data().write(to: folder.appendingPathComponent("main-invalid.txt"))
        try Data().write(to: folder.appendingPathComponent("unrelated.txt"))
        let (all, invalid) = try DiagnosticsReport.readHangs(directory: folder, interval: nil)
        #expect(all.count == 5 && invalid == 1)
        #expect(all.first?.date == Date(timeIntervalSince1970: 1007))
        let (selected, _) = try DiagnosticsReport.readHangs(directory: folder,
                                                            interval: .init(
                                                                start: Date(timeIntervalSince1970: 1000),
                                                                duration: 1
                                                            ))
        #expect(selected.count == 2)
        let (missing, _) = try DiagnosticsReport.readHangs(
            directory: folder.appendingPathComponent("missing"),
            interval: nil
        )
        #expect(missing.isEmpty)
    }

    @Test func `collects all sources and exports explicit time and current snapshot boundaries`() async throws {
        let now = Date(timeIntervalSince1970: 1000)
        let interval = DateInterval(start: now, duration: 10)
        var collector = DiagnosticsCollector()
        collector.readShortcuts = { date, range in
            #expect(date == now && range == interval)
            return .init(events: [], now: date)
        }
        collector.readHangs = { range in
            #expect(range == interval)
            return ([.init(date: now, bytes: 20, id: "main-1000-fixture.txt")], 0)
        }
        collector.resources = { [FeatureResourceSnapshot.capture(role: .host)] }
        collector.modules = { [.conversations: .init(state: .ready, generation: UUID(), pendingStarts: 0,
                                                     activeOperations: 2, hasLifecycleWork: false, failure: nil)] }
        let report = try await collector.collect(now: now, interval: interval)
        #expect(report.collectionFailures.isEmpty)
        #expect(report.currentModules?["conversations"]?.activeOperations == 2)
        #expect(report.shortcuts.processes?.count == 1)
        let data = try report.encodedForExport()
        let decoded = try JSONDecoder.isoDiagnostics.decode(DiagnosticsReport.self, from: data)
        #expect(decoded.rangeStart == now && decoded.rangeEnd == interval.end)
        #expect(decoded.hangs.count == 1)
        #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE STACK"))
        #expect(data.count < ShortcutLatencyReport.maximumExportBytes)
    }

    @Test func `marks missing sources instead of claiming healthy and propagates shortcut read failure`() async throws {
        var collector = DiagnosticsCollector()
        collector.readShortcuts = { date, _ in .init(events: [], now: date) }
        collector.resources = { throw ModuleFailure.unavailable }
        collector.modules = { throw ModuleFailure.unavailable }
        collector.readHangs = { _ in throw ModuleFailure.unavailable }
        let report = try await collector.collect(interval: nil)
        #expect(report.collectionFailures == ["resources", "modules", "hangs"])
        #expect(report.currentModules == nil && report.shortcuts.processes == nil)
        #expect(report.rangeStart == nil && report.rangeEnd == nil)
        collector.readShortcuts = { _, _ in throw ModuleFailure.unavailable }
        let partial = try await collector.collect(interval: nil)
        #expect(partial.collectionFailures == ["shortcuts", "resources", "modules", "hangs"])
        #expect(try partial.encodedForExport().count > 0)
    }
}

private extension JSONDecoder {
    static var isoDiagnostics: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
