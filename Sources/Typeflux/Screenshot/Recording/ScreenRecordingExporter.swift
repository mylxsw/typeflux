import Foundation

protocol ScreenRecordingExporting {
    func export(source: URL, destination: URL, format: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws
}

struct ScreenRecordingExporter: ScreenRecordingExporting {
    var encoder = ScreenRecordingEncoder.shared
    func export(source: URL, destination: URL, format: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        try await encoder.export(source: source, destination: destination, format: format, trim: trim, progress: progress)
    }
}

/// Keeps recoverable source files outside the temporary directory. Publishing is
/// prepared off-thread and committed separately under current authorization.
struct ScreenRecordingFiles {
    let root: URL
    var manager: FileManager = .default

    static var live: Self {
        Self(root: TypefluxDataDirectories.data.appendingPathComponent("Recordings", isDirectory: true))
    }

    func createSession(options: ScreenRecordingOptions) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(options).write(to: directory.appendingPathComponent("options.json"), options: .atomic)
        return directory
    }

    func recoverableSources() -> [URL] {
        ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent("source.mov") }
            .filter { manager.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    func discard(_ directory: URL) {
        // Only the directory owned by this feature can be removed.
        let canonical = directory.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == root.resolvingSymlinksInPath() else { return }
        ScreenRecordingEncodingOwnership.discard(canonical) { try? manager.removeItem(at: canonical) }
    }

    func preparePublication(
        _ source: URL, in directory: URL, format: ScreenRecordingFormat,
        date: Date = Date(), name: String? = nil, destinationURL: URL? = nil
    ) async throws -> ScreenRecordingPublication {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = name ?? ("Typeflux Recording " + formatter.string(from: date))
        return try await ScreenRecordingPublication.prepare(source: source, directory: directory, format: format,
            name: base, destination: destinationURL, protectedRoot: root)
    }
}
