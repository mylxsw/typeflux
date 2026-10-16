import Foundation

extension SemanticFileIndexer {
    // A directory is marked complete only after its final frame. Replaying an interrupted frame
    // inserts the same paths, so restart cannot lose descendants or create duplicate work.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    static func discover(scope: AskFileScope, store: SemanticFileStore, reader: AskFileReading,
                         roots: [String]? = nil,
                         paused: () -> Bool, cancelled: () -> Bool, summary: inout Summary,
                         progress: (Summary) -> Void) throws {
        try store.setStage(roots == nil ? .scanning : .incremental)
        if roots != nil {
            try store.record(.subtreeScans)
        }
        try store.beginDiscovery(scope: scope, roots: roots)
        while let path = try store.nextDirectory() {
            try waitWhilePaused(paused, cancelled: cancelled)
            var failed = false, writeFailure: Error?
            var next: AskDirectoryCursor?
            if scope.includes(path, isDirectory: true), !SemanticFilePolicy.isLegacyMediaArtifact(path),
               path != SemanticModel.directory.path {
                do {
                    let cursor = try store.directoryCursor(path)
                    try reader.stream(.init(operation: .directory, path: path, scope: scope, limit: nil,
                                            directoryCursor: cursor, paced: true),
                                      isCancelled: cancelled) { response in
                        if cancelled() {
                            return false
                        }
                        do { try waitWhilePaused(paused, cancelled: cancelled) }
                        catch { writeFailure = error; return false }
                        if let code = response.error, code != ENOENT, code != ENOTDIR {
                            failed = true
                        }
                        do {
                            if response.more != true {
                                next = response.directoryCursor
                            }
                            for mount in response.skippedMounts ?? [] {
                                try store.recordDirectories([mount]); try store.finishDirectory(mount, failed: true)
                            }
                            // Even an injected reader's large frame is committed in bounded transactions.
                            for start in stride(from: 0, to: response.entries.count, by: 128) {
                                try waitWhilePaused(paused, cancelled: cancelled)
                                let entries = response.entries[start ..< min(start + 128, response.entries.count)]
                                var directories: [String] = [], files: [(String, SemanticMediaPriority)] = []
                                for entry in entries {
                                    guard scope.includes(entry.path, isDirectory: entry.kind != .file) else { continue }
                                    if response.inspected == nil {
                                        summary.scanned += 1
                                    }
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
                            summary.scanned += response.inspected ?? 0
                            try store.record(.scanned, count: response.inspected ?? response.entries.count)
                            if response.more != true {
                                try store.checkpointDirectory(path, cursor: next)
                            }
                        } catch { writeFailure = error; return false }
                        return true
                    }
                } catch is SemanticWorkBudget.Interrupted {
                    try store.setStage(.waiting)
                    try SemanticWorkBudget.current?.checkpoint(cancelled: cancelled)
                    continue
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
            if next != nil, !failed {
                progress(summary)
                continue
            }
            try waitWhilePaused(paused, cancelled: cancelled)
            try store.finishDirectory(path, failed: failed)
            if failed {
                summary.skipped += 1
            }
        }
        // Includes entries committed by an earlier process during this scan.
        summary.discovered = try store.lock.withLock { try store.count("discovery") }
    }
}
