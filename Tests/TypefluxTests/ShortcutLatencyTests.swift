import Foundation
import Testing
@testable import Typeflux

@Suite("Shortcut latency recording")
struct ShortcutLatencyTests {
    private func trace(_ feature: FeatureRole = .launcher, at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ShortcutLatencyTrace {
        .init(id: UUID(), feature: feature, date: date, uptime: 100)
    }

    private func event(_ stage: ShortcutLatencyStage, trace: ShortcutLatencyTrace, at uptime: Double, pid: Int32 = 1) -> ShortcutLatencyEvent {
        .init(trace: trace, stage: stage, uptime: uptime, pid: pid, role: .launcher, build: "fixture")
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func joinsProcessesWithMonotonicDurationsAndKeepsIncompleteSamples() throws {
        let first = trace(), second = trace(.clipboard)
        let report = ShortcutLatencyReport(events: [
            event(.visibleNextTurn, trace: first, at: 100.25, pid: 3),
            event(.recognized, trace: second, at: 100, pid: 1),
            event(.recognized, trace: first, at: 100, pid: 1),
            event(.hostReceived, trace: first, at: 100.01, pid: 2),
            event(.targetCold, trace: first, at: 100.02, pid: 2)
        ])
        let sample = try #require(report.samples.first { $0.id == first.id })
        #expect(sample.events.map(\.pid) == [1, 2, 2, 3])
        #expect(sample.visibleMilliseconds == 250)
        #expect(sample.cold == true)
        #expect(sample.outcome == "visible")
        #expect(report.samples.first { $0.id == second.id }?.outcome == "incomplete")
    }

    @Test func distinguishesWarmColdAndUnknownAndNonDisplayOutcomes() {
        for stage in [ShortcutLatencyStage.failed, .blocked, .dismissed, .superseded] {
            let trace = trace()
            let sample = ShortcutLatencyReport(events: [event(stage, trace: trace, at: 101)]).samples[0]
            #expect(sample.outcome == stage.rawValue)
            #expect(sample.visibleMilliseconds == nil)
            #expect(sample.cold == nil)
        }
        let trace = trace()
        #expect(ShortcutLatencyReport(events: [event(.targetWarm, trace: trace, at: 100)]).samples[0].cold == false)
    }

    @Test func percentilesUseNearestRankAndHandleEmptyInput() {
        #expect(ShortcutLatencyReport.percentile([], fraction: 0.95) == nil)
        #expect(ShortcutLatencyReport.percentile([30, 10, 20, 100], fraction: 0.5) == 20)
        #expect(ShortcutLatencyReport.percentile([30, 10, 20, 100], fraction: 0.95) == 100)
    }

    @Test func summariesSeparateProcessStateAndExcludeNonVisibleDurations() throws {
        let first = trace(), second = trace(), third = trace()
        let report = ShortcutLatencyReport(events: [
            event(.targetCold, trace: first, at: 100), event(.visibleNextTurn, trace: first, at: 101),
            event(.targetWarm, trace: second, at: 100), event(.visibleNextTurn, trace: second, at: 100.25),
            event(.targetWarm, trace: third, at: 100), event(.failed, trace: third, at: 105)
        ])
        let warm = try #require(report.summaries.first { $0.temperature == "warm" })
        #expect(warm.samples == 2 && warm.visible == 1 && warm.other == 1)
        #expect(warm.p95Milliseconds == 250)
        #expect(report.summaries.first { $0.temperature == "cold" }?.p50Milliseconds == 1000)
        let chat = trace(.chat)
        #expect(ShortcutLatencyReport(events: [event(.handlerFinished, trace: chat, at: 101)]).samples[0].outcome == "handled")
    }

    @Test func rejectsConflictingTraceIdentityAndBoundsSamples() {
        let first = trace()
        let conflicting = ShortcutLatencyTrace(id: first.id, feature: .clipboard, date: first.date, uptime: first.uptime)
        #expect(ShortcutLatencyReport(events: [event(.recognized, trace: first, at: 100), event(.failed, trace: conflicting, at: 101)]).samples.isEmpty)
        let events = (0..<1005).map { index in
            event(.recognized, trace: trace(at: Date(timeIntervalSince1970: Double(index))), at: 100)
        }
        let report = ShortcutLatencyReport(events: events)
        #expect(report.samples.count == 1000)
        #expect(report.samples.first?.trace.date == Date(timeIntervalSince1970: 1004))
    }

    @Test func commandPreservesTraceAndDecodesLegacyMessages() throws {
        let trace = trace()
        let command = FeatureCommand(destination: .launcher, action: "toggleLauncher", latency: trace)
        #expect(try JSONDecoder().decode(FeatureCommand.self, from: JSONEncoder().encode(command)).latency == trace)
        let legacy = Data(#"{"destination":"launcher","action":"ping","payload":""}"#.utf8)
        #expect(try JSONDecoder().decode(FeatureCommand.self, from: legacy).latency == nil)
    }

    @Test func independentWritersJoinWithoutLoggingPayloads() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ShortcutLatencyWriter(directory: directory), second = ShortcutLatencyWriter(directory: directory)
        let trace = trace()
        first.record(event(.recognized, trace: trace, at: 100, pid: 1))
        second.record(event(.visibleNextTurn, trace: trace, at: 100.125, pid: 2))
        await first.flush(); await second.flush()
        let report = try ShortcutLatencyReport.read(directory: directory)
        #expect(report.samples.count == 1)
        #expect(report.samples[0].visibleMilliseconds == 125)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            #expect(permissions == 0o600)
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(Set(object.keys) == ["version", "trace", "stage", "uptime", "pid", "role", "build", "droppedBefore"])
        }
    }

    @Test func skipsPartialWritesAndCountsMalformedRecords() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event(.recognized, trace: trace(), at: 100))
        data.append(contentsOf: Data("\ninvalid\n{\"partial\":".utf8))
        try data.write(to: directory.appendingPathComponent("events-fixture.jsonl"))
        let report = try ShortcutLatencyReport.read(directory: directory)
        #expect(report.samples.count == 1)
        #expect(report.invalidLines == 1)
        #expect(report.unreadableFiles == 0)
    }

    @Test func rejectsInvalidClockAndProtocolAndSkipsOversizeFiles() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var invalid = event(.recognized, trace: trace(), at: 99)
        var data = try encoder.encode(invalid); data.append(10)
        invalid.version = 3
        try data.append(encoder.encode(invalid)); data.append(10)
        try data.write(to: directory.appendingPathComponent("events-invalid.jsonl"))
        try Data(count: ShortcutLatencyWriter.maximumFileBytes + 1).write(to: directory.appendingPathComponent("events-oversize.jsonl"))
        let report = try ShortcutLatencyReport.read(directory: directory)
        #expect(report.invalidLines == 2)
        #expect(report.unreadableFiles == 1)
        #expect(report.samples.isEmpty)
    }

    @Test func retentionLeavesUnrelatedFilesAlone() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<4 { try Data().write(to: directory.appendingPathComponent("events-\(index).jsonl")) }
        let expired = directory.appendingPathComponent("events-expired.jsonl")
        try Data().write(to: expired)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: expired.path)
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data().write(to: unrelated)
        try ShortcutLatencyWriter.prune(directory: directory, keeping: 2)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 3)
    }

    @Test func missingDirectoryIsEmptyAndExportRetainsStages() throws {
        #expect(try ShortcutLatencyReport.read(directory: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")).samples.isEmpty)
        let trace = trace()
        let report = ShortcutLatencyReport(events: [event(.recognized, trace: trace, at: 100)])
        let decoded = try JSONDecoder().decode(ShortcutLatencyReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.samples[0].events[0].stage == .recognized)
    }
}


extension ShortcutLatencyTests {
    @Test func processSnapshotsCanBeExportedWithoutShortcutSamples() throws {
        var report = ShortcutLatencyReport(events: [])
        #expect(!report.canExport)
        report.processes = [.init(role: .host, pid: 42, startedAt: 1, uptime: 2, footprintBytes: 1024,
            cpuNanoseconds: 100, managedOperations: 0, helperSlots: 0)]
        #expect(report.canExport)
        let decoded = try JSONDecoder().decode(ShortcutLatencyReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.canExport && decoded.processes?.first?.footprintBytes == 1024)
    }
}
