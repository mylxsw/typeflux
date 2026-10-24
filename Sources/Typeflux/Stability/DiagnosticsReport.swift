import Foundation

/// Time selection applies to trace start times, keeping each selected trace intact.
/// Current resources and health are deliberately separate from historical records.
struct DiagnosticsReport: Codable, Sendable {
    struct HangRecord: Codable, Identifiable, Sendable {
        let date: Date
        let bytes: Int
        let id: String
    }

    var version = 1
    let generatedAt: Date
    let rangeStart: Date?
    let rangeEnd: Date?
    let shortcuts: ShortcutLatencyReport
    var previousProcesses: [FeatureResourceSnapshot]? = nil
    let currentSnapshotAt: Date
    let currentModules: [String: ModuleHealth]?
    let hangs: [HangRecord]
    let unreadableHangFiles: Int
    let collectionFailures: [String]
    var askFailures: [AskFailureDiagnostics.Event]? = nil

    static var hangDirectory: URL {
        TypefluxDataDirectories.cache.appendingPathComponent("hang-diagnostics", isDirectory: true)
    }

    static func readHangs(directory: URL = hangDirectory, interval: DateInterval?) throws -> ([HangRecord], Int) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )
        var records: [HangRecord] = [], unreadable = 0
        for file in files where file.lastPathComponent.hasPrefix("main-") && file.pathExtension == "txt" {
            let components = file.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard components.count >= 2, let seconds = Double(components[1]),
                  seconds.isFinite else { unreadable += 1; continue }
            let date = Date(timeIntervalSince1970: seconds)
            guard interval.map({ date >= $0.start && date <= $0.end }) ?? true else { continue }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { unreadable += 1; continue }
            // Never include stack contents, usernames or absolute paths in the JSON bundle.
            records.append(.init(date: date, bytes: size, id: file.lastPathComponent))
        }
        return (Array(records.sorted { $0.date > $1.date }.prefix(5)), unreadable)
    }

    func encodedForExport() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= ShortcutLatencyReport.maximumExportBytes
        else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return data
    }
}
