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
        // Old recordings did not instrument ring/translation presentation. Keep
        // those as unmeasured handlers rather than implying a missing v2 terminal.
        if [.ring, .translation].contains(trace.feature), events.allSatisfy({ $0.version == 1 }),
           events.contains(where: { $0.stage == .handlerFinished }) {
            return "handled"
        }
        if ![FeatureRole.launcher, .clipboard, .screenshot, .ring, .translation].contains(trace.feature),
           events.contains(where: { $0.stage == .handlerFinished }) {
            return "handled"
        }
        return "incomplete"
    }
    var visibleMilliseconds: Double? { events.first { $0.stage == .visibleNextTurn }?.milliseconds }
}

struct ShortcutLatencyReport: Codable, Sendable {
    static let maximumSamples = 200
    static let maximumEventsPerSample = 128
    static let maximumEvents = 2048
    static let maximumExportBytes = 2 * 1024 * 1024
    struct Summary: Codable, Sendable {
        let feature: FeatureRole
        let temperature: String
        let samples: Int
        let visible: Int
        let other: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
    }
    var processes: [FeatureResourceSnapshot]? = nil
    var canExport: Bool { !samples.isEmpty || !(processes?.isEmpty ?? true) }
    let generatedAt: Date
    let samples: [ShortcutLatencySample]
    let summaries: [Summary]
    let unreadableFiles: Int
    let invalidLines: Int
    private(set) var droppedEvents: Int

    init(events: [ShortcutLatencyEvent], unreadableFiles: Int = 0, invalidLines: Int = 0, now: Date = Date()) {
        generatedAt = now; self.unreadableFiles = unreadableFiles; self.invalidLines = invalidLines
        droppedEvents = events.reduce(0) { $0 + $1.droppedBefore }
        let grouped = Dictionary(grouping: events, by: { $0.trace.id }).compactMap { _, values -> ShortcutLatencySample? in
            guard let trace = values.first?.trace, values.allSatisfy({ $0.trace == trace }) else { return nil }
            let ordered = values.sorted { $0.uptime < $1.uptime }
            // Keep the start and the tail, including failures/visibility after a routing storm.
            let bounded = ordered.count <= Self.maximumEventsPerSample ? ordered
                : Array(ordered.prefix(96)) + Array(ordered.suffix(32))
            return ShortcutLatencySample(trace: trace, events: bounded)
        }.sorted { $0.trace.date > $1.trace.date }
        var retained: [ShortcutLatencySample] = [], count = 0
        for sample in grouped.prefix(Self.maximumSamples) {
            guard count + sample.events.count <= Self.maximumEvents else { break }
            retained.append(sample); count += sample.events.count
        }
        samples = retained
        droppedEvents += events.count - count
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

    func filteredSamples(feature: String, temperature: String) -> [ShortcutLatencySample] {
        samples.filter {
            (feature == "all" || $0.trace.feature.rawValue == feature) &&
                (temperature == "all" || ($0.cold.map { $0 ? "cold" : "warm" } ?? "unknown") == temperature)
        }
    }

    func selecting(feature: String, temperature: String) -> Self {
        let selected = filteredSamples(feature: feature, temperature: temperature)
        var result = Self(events: selected.flatMap(\.events), unreadableFiles: unreadableFiles,
                          invalidLines: invalidLines, now: generatedAt)
        result.processes = processes
        result.droppedEvents = droppedEvents
        return result
    }

    /// Compact JSON and a byte ceiling protect exports even when reading old runaway logs.
    func encodedForExport() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var snapshot = self
        while true {
            let data = try encoder.encode(snapshot)
            if data.count <= Self.maximumExportBytes { return data }
            guard let last = snapshot.samples.last else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            let events = snapshot.samples.dropLast().flatMap(\.events)
            var reduced = Self(events: events, unreadableFiles: unreadableFiles, invalidLines: invalidLines, now: generatedAt)
            reduced.processes = processes
            reduced.droppedEvents = snapshot.droppedEvents + last.events.count
            snapshot = reduced
        }
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
                      [1, 2].contains(event.version), event.trace.uptime.isFinite, event.uptime.isFinite,
                      event.uptime >= event.trace.uptime, event.uptime - event.trace.uptime <= 300,
                      event.droppedBefore >= 0, event.droppedBefore <= 1_000_000,
                      event.build.utf8.count <= 128 else { invalid += 1; continue }
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
            print(String(decoding: try report.encodedForExport(), as: UTF8.self)); return 0
        } catch { fputs("Could not read shortcut diagnostics\n", stderr); return 1 }
    }
}
