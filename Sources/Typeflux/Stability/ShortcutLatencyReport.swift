import Foundation

struct ShortcutLatencySample: Identifiable, Codable, Sendable {
    let trace: ShortcutLatencyTrace
    let events: [ShortcutLatencyEvent]
    var id: UUID { trace.id }
    var cold: Bool? {
        if events.contains(where: { $0.stage == .targetCold }) { return true }
        if events.contains(where: { $0.stage == .targetWarm }) { return false }
        return nil
    }
    var outcome: String {
        if events.contains(where: { $0.stage == .visibleNextTurn }) { return "visible" }
        for stage in [ShortcutLatencyStage.failed, .blocked, .dismissed, .superseded] {
            if events.contains(where: { $0.stage == stage }) { return stage.rawValue }
        }
        if ![FeatureRole.launcher, .clipboard, .screenshot].contains(trace.feature),
           events.contains(where: { $0.stage == .handlerFinished }) { return "handled" }
        return "incomplete"
    }
    var visibleMilliseconds: Double? { events.first { $0.stage == .visibleNextTurn }?.milliseconds }
}

struct ShortcutLatencyReport: Codable, Sendable {
    struct Summary: Codable, Sendable {
        let feature: FeatureRole
        let temperature: String
        let samples: Int
        let visible: Int
        let other: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
    }
    let generatedAt: Date
    let samples: [ShortcutLatencySample]
    let summaries: [Summary]
    let unreadableFiles: Int
    let invalidLines: Int
    let droppedEvents: Int

    init(events: [ShortcutLatencyEvent], unreadableFiles: Int = 0, invalidLines: Int = 0, now: Date = Date()) {
        generatedAt = now; self.unreadableFiles = unreadableFiles; self.invalidLines = invalidLines
        droppedEvents = events.reduce(0) { $0 + $1.droppedBefore }
        samples = Dictionary(grouping: events, by: { $0.trace.id }).compactMap { _, values in
            guard let trace = values.first?.trace, values.allSatisfy({ $0.trace == trace }) else { return nil }
            return ShortcutLatencySample(trace: trace, events: values.sorted { $0.uptime < $1.uptime })
        }.sorted { $0.trace.date > $1.trace.date }.prefix(1000).map { $0 }
        var summaries: [Summary] = []
        for feature in FeatureRole.allCases {
            for temperature in ["all", "cold", "warm", "unknown"] {
                let selected = samples.filter {
                    $0.trace.feature == feature && (temperature == "all" ||
                        ($0.cold.map { $0 ? "cold" : "warm" } ?? "unknown") == temperature)
                }
                guard !selected.isEmpty else { continue }
                let values = selected.compactMap(\.visibleMilliseconds)
                summaries.append(.init(feature: feature, temperature: temperature, samples: selected.count,
                                       visible: values.count, other: selected.count - values.count,
                                       p50Milliseconds: Self.percentile(values, fraction: 0.5),
                                       p95Milliseconds: Self.percentile(values, fraction: 0.95)))
            }
        }
        self.summaries = summaries
    }

    static func read(directory: URL = ShortcutLatency.directory, now: Date = Date()) throws -> Self {
        guard FileManager.default.fileExists(atPath: directory.path) else { return .init(events: [], now: now) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var events: [ShortcutLatencyEvent] = [], unreadable = 0, invalid = 0
        for file in files.prefix(ShortcutLatencyWriter.maximumFiles) {
            guard let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  (attributes.fileSize ?? Int.max) <= ShortcutLatencyWriter.maximumFileBytes,
                  let data = try? Data(contentsOf: file) else { unreadable += 1; continue }
            if now.timeIntervalSince(attributes.contentModificationDate ?? .distantPast) > ShortcutLatencyWriter.retention { continue }
            let lines = data.split(separator: 10, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                // A live writer may be halfway through the last line. Try it on the next refresh.
                if index == lines.count - 1, data.last != 10 { continue }
                guard let event = try? decoder.decode(ShortcutLatencyEvent.self, from: Data(line)),
                      event.version == 1, event.trace.uptime.isFinite, event.uptime.isFinite,
                      event.uptime >= event.trace.uptime, event.uptime - event.trace.uptime <= 300,
                      event.droppedBefore >= 0 else { invalid += 1; continue }
                events.append(event)
            }
        }
        return .init(events: events, unreadableFiles: unreadable, invalidLines: invalid, now: now)
    }

    static func percentile(_ values: [Double], fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }
}

/// The UI and CLI use the same bounded parser and schema. This command never
/// initializes AppKit, opens user content, or starts a feature process.
public enum ShortcutDiagnosticsCommand {
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--directory") else {
            fputs("Usage: Typeflux shortcut-diagnostics [--directory PATH]\n", stderr); return 64
        }
        do {
            let directory = arguments.count == 2 ? URL(fileURLWithPath: arguments[1], isDirectory: true) : ShortcutLatency.directory
            let report = try ShortcutLatencyReport.read(directory: directory)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self)); return 0
        } catch { fputs("Could not read shortcut diagnostics\n", stderr); return 1 }
    }
}
