import Foundation

enum HistoryExportDestination {
    static func downloadsDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
    }

    static func moveExport(
        at sourceURL: URL,
        to directoryURL: URL,
        fileManager: FileManager = .default,
    ) throws -> URL {
        let destinationURL = directoryURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)

        if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
