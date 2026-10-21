import Darwin
import Foundation

extension AskFileTools {
    func list(_ path: String) throws -> String {
        let access = try AskFileAccess(AskFileAccess.location(path, roots: roots), directory: true, hooks: hooks)
        var lines: [String] = [], truncated = false, visited = 0, bytes = 0
        try AskFileAccess.enumerate(access.descriptor) { name in
            try hooks.onEvent?("entry")
            visited += 1
            if visited > Self.maximumListEntries {
                truncated = true; return false
            }
            if name.hasPrefix(".") {
                return true
            }
            var info = stat()
            guard fstatat(access.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            else { throw AskFileAccess.conflict }
            let line = info.st_mode & S_IFMT == S_IFDIR ? "\(name)/" : "\(name)  \(info.st_size) bytes"
            if bytes + line.utf8.count > 48000 {
                truncated = true; return false
            }
            bytes += line.utf8.count + 1; lines.append(line)
            return true
        }
        try hooks.onEvent?("release")
        try access.revalidate()
        let header = "Folder: \(access.location.path)\n"
        return header + lines.sorted()
            .joined(separator: "\n") +
            (truncated ? "\n[Partial listing; more entries may exist. Only the captured entries are sorted.]" : lines
                .isEmpty ? "(empty)" : "")
    }

    // Keep lazy traversal and its shared per-request budgets in one scope.
    // swiftlint:disable:next function_body_length
    func search(_ path: String, pattern: String) throws -> String {
        guard !pattern.isEmpty, pattern.utf8.count <= 2000,
              pattern.count <= 500 else { throw AskFileAccess.error(L("ask.tool.invalid")) }
        let location = try AskFileAccess.location(path, roots: roots)
        // Determine type using a no-follow descriptor, never a path resource query.
        let root = try AskFileAccess.openRoot(location.root)
        var parent = root
        for component in location.parts.dropLast() {
            parent = try parent.child(component)
        }
        var info = stat()
        guard fstatat(parent.descriptor, location.parts.last ?? ".", &info, AT_SYMLINK_NOFOLLOW) == 0
        else { throw AskFileAccess.denied }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let start = try AskFileAccess(location, directory: isDirectory, hooks: hooks)
        var entries = 0, readBytes = 0, skipped = 0, outputBytes = 0
        var partial = false, matches: [String] = []
        let totalBudget = 32 * 1024 * 1024
        var stopped: Bool {
            entries >= 5000 || readBytes >= totalBudget || matches.count >= Self.maximumMatches || outputBytes >= 48000
        }

        struct Observation {
            var file: AskFileAccess.Location
            var version: String
            var rootIdentity: String
            var parentIdentity: String
        }
        var observations: [Observation] = []
        func inspect(_ file: AskFileAccess.Location) throws {
            guard !stopped else { partial = true; return }
            do {
                let available = totalBudget - readBytes
                guard available > 0 else { partial = true; return }
                let counter = AskFileByteCounter()
                var fileHooks = hooks
                fileHooks.onBytes = { count in counter.add(count); try hooks.onBytes?(count) }
                let access = try AskFileAccess(file, hooks: fileHooks)
                guard access.initial!.st_size <= Self.maximumSearchFileBytes else { skipped += 1; return }
                let data: Data
                do { data = try access.boundedData(limit: Self.maximumSearchFileBytes, budget: available - 1) }
                catch { readBytes += counter.value; throw error }
                readBytes += counter.value
                _ = try AskProjectFileAccess.text(data)
                var local: [String] = [], localBytes = 0, start = 0, lineNumber = 1
                for end in 0 ... data.count where end == data.count || data[end] == 10 {
                    try Task.checkCancellation()
                    let line = String(decoding: data[start ..< end], as: UTF8.self)
                    if line.range(of: pattern, options: [.caseInsensitive, .literal]) != nil {
                        let preview = AskProjectFileAccess.preview(line, maximumBytes: 800)
                        let match = "\(file.path):\(lineNumber): \(preview)"
                        if outputBytes + localBytes + match.utf8.count + 1 > 48000 {
                            partial = true; break
                        }
                        local.append(match); localBytes += match.utf8.count + 1
                        if matches.count + local.count == Self.maximumMatches {
                            partial = true; break
                        }
                    }
                    start = end + 1; lineNumber += 1
                }
                try hooks.onEvent?("release")
                try access.revalidate()
                if !local.isEmpty {
                    observations.append(Observation(
                        file: file,
                        version: access.version,
                        rootIdentity: access.rootIdentity,
                        parentIdentity: access.parentIdentity
                    ))
                }
                matches.append(contentsOf: local); outputBytes += localBytes
            } catch is CancellationError { throw CancellationError() }
            catch { skipped += 1; partial = true }
        }
        func visit(_ directory: AskFileAccess, depth: Int) throws {
            try AskFileAccess.enumerate(directory.descriptor) { name in
                try hooks.onEvent?("entry")
                guard !stopped else { partial = true; return false }
                entries += 1
                if name.hasPrefix(".") {
                    return true
                }
                let child = AskFileAccess.Location(root: location.root, parts: directory.location.parts + [name])
                var value = stat()
                guard fstatat(directory.descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0
                else { skipped += 1; partial = true; return true }
                if value.st_mode & S_IFMT == S_IFDIR {
                    if depth >= 16 {
                        skipped += 1; partial = true
                    } else {
                        do { try visit(AskFileAccess(child, directory: true, hooks: hooks), depth: depth + 1) }
                        catch is CancellationError { throw CancellationError() }
                        catch { skipped += 1; partial = true }
                    }
                } else if value.st_mode & S_IFMT == S_IFREG {
                    try inspect(child)
                } else {
                    skipped += 1
                }
                return true
            }
            try directory.revalidate()
        }
        if isDirectory {
            try visit(start, depth: 0)
        } else {
            try inspect(location)
        }
        try start.revalidate()
        // Retain only bounded metadata for matching files, not open file buffers.
        // Revalidate again immediately before releasing the aggregate result.
        for observation in observations {
            let current = try AskFileAccess(observation.file, hooks: hooks)
            guard current.version == observation.version, current.rootIdentity == observation.rootIdentity,
                  current.parentIdentity == observation.parentIdentity else { throw AskFileAccess.conflict }
            try current.revalidate()
        }
        try Task.checkCancellation()
        if skipped > 0 {
            partial = true
        }
        var result = matches.isEmpty ? (partial ? "No matches in the inspected portion." : "No matches.") : matches
            .joined(separator: "\n")
        if partial {
            result +=
                "\n[Partial search; \(entries) entries visited, \(readBytes) bytes read, \(skipped) skipped. Narrow the path or pattern.]"
        }
        try Task.checkCancellation()
        return result
    }
}

/// Per-request accounting shared with a synchronous read callback.
private final class AskFileByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }; count += bytes
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }; return count
    }
}
