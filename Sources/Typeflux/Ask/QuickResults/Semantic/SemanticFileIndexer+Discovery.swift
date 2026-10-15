import Foundation

extension SemanticFileIndexer {
    // A directory is marked complete only after its final frame. Replaying an interrupted frame
    // inserts the same paths, so restart cannot lose descendants or create duplicate work.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func discover(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                         paused: () -> Bool, cancelled: () -> Bool, summary: inout Summary,
                         progress: (Summary) -> Void) throws {
        try store.beginDiscovery(scope: scope)
        while let path = try store.nextDirectory() {
            try waitWhilePaused(paused, cancelled: cancelled)
            var failed = !scope.includes(path, isDirectory: true), writeFailure: Error?
            if !failed {
                do {
                    try reader.stream(.init(operation: .directory, path: path, scope: scope, limit: nil),
                                      isCancelled: cancelled) { response in
                        if cancelled() {
                            return false
                        }
                        if let code = response.error, code != ENOENT, code != ENOTDIR {
                            failed = true
                        }
                        do {
                            for mount in response.skippedMounts ?? [] {
                                try store.recordDirectories([mount]); try store.finishDirectory(mount, failed: true)
                            }
                            // Even an injected reader's large frame is committed in bounded transactions.
                            for start in stride(from: 0, to: response.entries.count, by: 128) {
                                let entries = response.entries[start ..< min(start + 128, response.entries.count)]
                                var directories: [String] = [], files: [(String, SemanticMediaPriority)] = []
                                for entry in entries {
                                    guard scope.includes(entry.path, isDirectory: entry.kind != .file) else { continue }
                                    summary.scanned += 1
                                    if entry.kind == .folder {
                                        directories.append(entry.path)
                                    }
                                    if entry.kind == .file, SemanticFilePolicy.allows(entry.path) {
                                        files.append((entry.path, SemanticMediaPriority.of(entry.path)))
                                    }
                                }
                                try store.recordDirectories(directories)
                                summary.discovered += try store.discover(files)
                                if summary.scanned.isMultiple(of: 1000) {
                                    progress(summary)
                                }
                            }
                        } catch { writeFailure = error; return false }
                        return true
                    }
                } catch {
                    if cancelled() {
                        throw CancellationError()
                    }
                    failed = true
                }
            }
            if cancelled() {
                throw CancellationError()
            }
            if let writeFailure {
                throw writeFailure
            }
            try store.finishDirectory(path, failed: failed)
            if failed {
                summary.skipped += 1
            }
        }
        // Includes entries committed by an earlier process during this scan.
        summary.discovered = try store.lock.withLock { try store.count("discovery") }
    }
}
