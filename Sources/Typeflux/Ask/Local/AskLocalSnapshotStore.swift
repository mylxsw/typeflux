import Foundation

/// Opaque local adapter snapshots. Encoding and recovery belong to the engine.
protocol AskLocalSnapshotStoring: Sendable {
    func loadSnapshots() -> [Data]
    func writeSnapshot(_ data: Data, id: String) throws
    func removeSnapshot(id: String) throws
}

struct FileAskLocalSnapshotStore: AskLocalSnapshotStoring {
    let directory: URL

    func loadSnapshots() -> [Data] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? Data(contentsOf: $0) }
    }

    func writeSnapshot(_ data: Data, id: String) throws {
        let file = try file(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    func removeSnapshot(id: String) throws {
        try FileManager.default.removeItem(at: file(id))
    }

    private func file(_ id: String) throws -> URL {
        guard AskStorageIdentifier.isValid(id) else { throw AskLocalError.message(L("ask.local.notFound")) }
        return directory.appendingPathComponent(id + ".json")
    }
}
