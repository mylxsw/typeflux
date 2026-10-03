import Darwin
import Foundation

/// Builds a bounded private copy while D01 holds its manifest lock. No source
/// descriptors or processes escape the callback. Git metadata is never copied.
enum AskProjectExecutionCopy {
    static let maximumEntries = 1024
    static let maximumBytes = 32 * 1024 * 1024

    // Keep traversal and all per-copy evidence in one bounded transaction.
    // swiftlint:disable:next function_body_length
    static func prepare(_ state: AskProjectChangeSet, access: AskProjectFileAccess,
                        destination: AskSecureDirectory, beforeValidation: (() throws -> Void)? = nil) throws {
        var files: [String: String] = [:], directories: [String: String] = [:]
        var bytes = 0, entries = 0
        let staged = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.path, $0.updated) })

        func write(_ data: Data, path: String) throws {
            guard data.count <= maximumBytes - bytes else { throw AskProjectError.tooLarge }
            bytes += data.count
            let parts = try AskProjectFileAccess.parts(path)
            guard parts.count <= 17 else { throw AskProjectError.tooLarge }
            var parent = destination
            for part in parts.dropLast() {
                parent = try parent.child(part, create: true, privateDirectory: true)
            }
            try parent.createFile(parts.last!, data: data)
        }

        func visit(_ directory: AskSecureDirectory, path: String, depth: Int) throws {
            guard depth <= 16 else { throw AskProjectError.tooLarge }
            let before = try stamp(directory)
            let names = try listing(directory)
            directories[path] = before
            for name in names where name.lowercased() != ".git" {
                entries += 1
                guard entries <= maximumEntries else { throw AskProjectError.tooLarge }
                let relative = path == "." ? name : path + "/" + name
                _ = try AskProjectFileAccess.parts(relative)
                var info = stat()
                guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw AskProjectError.conflict
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    var target = destination
                    for part in try AskProjectFileAccess.parts(relative) {
                        target = try target.child(part, create: true, privateDirectory: true)
                    }
                    try visit(directory.child(name), path: relative, depth: depth + 1)
                } else {
                    let snapshot = try access.snapshot(relative)
                    guard let data = snapshot.data else { throw AskProjectError.conflict }
                    files[relative] = snapshot.version
                    try write(staged[relative] ?? data, path: relative)
                }
            }
            guard try stamp(directory) == before,
                  try listing(directory) == names else { throw AskProjectError.conflict }
        }

        try visit(access.directory, path: ".", depth: 0)
        for entry in state.entries where files[entry.path] == nil {
            let snapshot = try access.snapshot(entry.path)
            guard snapshot.version == entry.sourceVersion else { throw AskProjectError.conflict }
            files[entry.path] = snapshot.version
            // Charge staged parent directories conservatively against the copy budget.
            entries += try AskProjectFileAccess.parts(entry.path).count
            guard entries <= maximumEntries else { throw AskProjectError.tooLarge }
            try write(entry.updated, path: entry.path)
        }
        try beforeValidation?()
        for (path, version) in files {
            guard try access.snapshot(path).version == version else { throw AskProjectError.conflict }
        }
        for (path, version) in directories {
            var directory = access.directory
            if path != "." {
                for part in try AskProjectFileAccess.parts(path) {
                    directory = try directory.child(part)
                }
            }
            guard try stamp(directory) == version else { throw AskProjectError.conflict }
        }
    }

    private static func stamp(_ directory: AskSecureDirectory) throws -> String {
        var info = stat()
        guard fstat(directory.descriptor, &info) == 0 else { throw AskProjectError.denied }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):" +
            "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private static func listing(_ directory: AskSecureDirectory) throws -> [String] {
        let fileDescriptor = openat(directory.descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { throw AskProjectError.denied }
        guard let stream = fdopendir(fileDescriptor) else { close(fileDescriptor); throw AskProjectError.denied }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw AskProjectError.denied }
                return result.sorted()
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                result.append(name)
            }
            guard result.count <= 500 else { throw AskProjectError.tooLarge }
        }
    }
}
