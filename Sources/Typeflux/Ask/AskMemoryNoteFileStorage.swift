import Foundation

/// A failed write must leave the previous destination intact. The store publishes
/// its candidate in memory only after this atomic commit succeeds.
protocol AskMemoryNoteFileStorage {
    func read(from url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
}

struct LocalAskMemoryNoteFileStorage: AskMemoryNoteFileStorage {
    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
