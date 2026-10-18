import Foundation

/// Files opened from Typeflux, attributed only when the destination application is known.
@MainActor
final class AskAppContinueHistory {
    struct Record: Codable, Equatable, Identifiable {
        var applicationID: String
        var path: String
        var openedAt: Date

        var id: String { applicationID + ":" + path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    private static let key = "ask.launcher.appContinue.files"
    private let defaults: UserDefaults
    private var records: [Record]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        records = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    func record(_ file: URL, applicationID: String) {
        guard file.isFileURL else { return }
        let path = file.standardizedFileURL.path
        records.removeAll { $0.applicationID == applicationID && $0.path == path }
        records.insert(Record(applicationID: applicationID, path: path, openedAt: Date()), at: 0)
        records = Array(records.prefix(100))
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
    }

    func recent(for app: AskAppEntry, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Record] {
        Array(records.filter { $0.applicationID == app.id && exists($0.path) }.prefix(12))
    }
}
