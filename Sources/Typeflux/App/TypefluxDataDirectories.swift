import Foundation

/// File-backed Typeflux data lives below one user-owned directory. System-managed
/// preferences and Keychain items retain their platform storage and access rules.
enum TypefluxDataDirectories {
    struct Layout {
        let data: URL
        let workspaces: URL
        let cache: URL
        let migrationErrors: [String]
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var active: Layout?

        var layout: Layout {
            lock.lock()
            defer { lock.unlock() }
            return active ?? TypefluxDataDirectories.unmigratedLayout(
                home: FileManager.default.homeDirectoryForCurrentUser
            )
        }

        func prepare() {
            lock.lock()
            defer { lock.unlock() }
            guard active == nil else { return }
            active = TypefluxDataDirectories.migrate(
                home: FileManager.default.homeDirectoryForCurrentUser, fileManager: .default
            )
        }
    }

    private static let state = State()

    static var data: URL { state.layout.data }
    static var workspaces: URL { state.layout.workspaces }
    static var cache: URL { state.layout.cache }

    /// Resolve paths before any storage service opens its files.
    static func prepare() {
        state.prepare()
        for error in state.layout.migrationErrors {
            NSLog("Typeflux data migration: %@", error)
        }
    }

    private static func unmigratedLayout(home: URL) -> Layout {
        let root = home.appendingPathComponent(".typeflux", isDirectory: true)
        return Layout(data: root.appendingPathComponent("data", isDirectory: true),
                      workspaces: root.appendingPathComponent("workspaces", isDirectory: true),
                      cache: root.appendingPathComponent("cache", isDirectory: true),
                      migrationErrors: [])
    }

    static func migrate(home: URL, fileManager: FileManager) -> Layout {
        let root = home.appendingPathComponent(".typeflux", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Typeflux", isDirectory: true)
        let documents = home.appendingPathComponent("Documents/Typeflux/Workspaces", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches/Typeflux", isDirectory: true)
        var errors: [String] = []

        do {
            guard (try? fileManager.destinationOfSymbolicLink(atPath: root.path)) == nil else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            errors.append("Cannot create \(root.path): \(error.localizedDescription)")
            return Layout(data: support, workspaces: documents, cache: caches, migrationErrors: errors)
        }

        func destination(_ name: String, from source: URL) -> URL {
            let target = root.appendingPathComponent(name, isDirectory: true)
            do {
                if let link = try? fileManager.destinationOfSymbolicLink(atPath: source.path) {
                    let resolved = URL(fileURLWithPath: link, relativeTo: source.deletingLastPathComponent())
                        .standardizedFileURL
                    if resolved == target.standardizedFileURL { return target }
                    errors.append("Unexpected symbolic link at \(source.path); using the original location")
                    return source
                }
                if (try? fileManager.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    errors.append("Unexpected symbolic link at \(target.path); using the original location")
                    return source
                }
                let sourceExists = fileManager.fileExists(atPath: source.path)
                let targetExists = fileManager.fileExists(atPath: target.path)
                if sourceExists, targetExists {
                    // A prior partial migration or an independently populated destination
                    // needs a deliberate merge. Keep reading the original data meanwhile.
                    errors.append("Both \(source.path) and \(target.path) exist; using the original directory")
                    return source
                }
                if sourceExists {
                    try fileManager.moveItem(at: source, to: target)
                    // Existing records can contain absolute paths. Preserve those paths
                    // without keeping another copy of the data.
                    do {
                        try fileManager.createSymbolicLink(at: source, withDestinationURL: target)
                    } catch {
                        errors.append("Cannot link old path \(source.path) to \(target.path): \(error.localizedDescription)")
                    }
                } else if !targetExists {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
                }
                return target
            } catch {
                errors.append("Cannot move \(source.path) to \(target.path): \(error.localizedDescription)")
                return source
            }
        }

        return Layout(data: destination("data", from: support),
                      workspaces: destination("workspaces", from: documents),
                      cache: destination("cache", from: caches),
                      migrationErrors: errors)
    }
}
