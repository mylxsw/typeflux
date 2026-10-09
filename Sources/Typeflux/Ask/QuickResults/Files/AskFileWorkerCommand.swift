import Darwin
import Foundation

/// Private line-delimited protocol between the index and its disposable file-system worker.
struct AskFileReadRequest: Codable {
    enum Operation: String, Codable { case directory, entry, resolve }
    var operation: Operation
    var path: String
    var scope: AskFileScope?
    var blocked: [String] = []
    var limit: Int = AskFileCrawler.maximumEntries
}

struct AskFileReadResponse: Codable {
    var entries: [AskFileCrawler.Entry] = []
    var path: String?
    var error: Int32?
    var more: Bool?
    var skippedMounts: [String]?
}

/// Runs before AppKit startup. Only this child performs potentially stuck directory reads.
public enum AskFileWorkerCommand {
    public static func run() -> Int32 {
        while let line = readLine() {
            guard let request = try? JSONDecoder().decode(AskFileReadRequest.self, from: Data(line.utf8)) else { return 1 }
            do {
                try stream(request) { response in
                    let data = try JSONEncoder().encode(response)
                    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
                }
            } catch { return 1 }
        }
        return 0
    }

    /// Synchronous adapter for deterministic policy tests and small metadata requests.
    static func handle(_ request: AskFileReadRequest) -> AskFileReadResponse {
        var result = AskFileReadResponse()
        try? stream(request) { frame in
            result.entries += frame.entries
            result.path = frame.path ?? result.path
            result.error = frame.error ?? result.error
            result.skippedMounts = (result.skippedMounts ?? []) + (frame.skippedMounts ?? [])
        }
        return result
    }

    static func stream(_ request: AskFileReadRequest, mounts: AskFileMounts = .current(),
                       emit: (AskFileReadResponse) throws -> Void) throws {
        // Acknowledge startup separately from directory progress; the first syscall gets an idle deadline.
        try emit(AskFileReadResponse(more: true))
        try emit(try response(request, mounts: mounts, emit: emit))
    }

    private static func response(_ request: AskFileReadRequest, mounts: AskFileMounts,
                                 emit: (AskFileReadResponse) throws -> Void) throws -> AskFileReadResponse {
        if request.operation == .resolve {
            return AskFileReadResponse(path: resolve(request.path, blocked: request.blocked, mounts: mounts))
        }
        guard let scope = request.scope,
              (scope.includes(request.path, isDirectory: true)
                || (request.operation == .entry && scope.includes(request.path, isDirectory: false))) else {
            return AskFileReadResponse(error: EACCES)
        }
        if let mount = mounts.blocking(request.path) { return AskFileReadResponse(skippedMounts: [mount]) }
        if request.operation == .entry {
            // Check every ancestor without following links before lstat of the leaf.
            let parent = (request.path as NSString).deletingLastPathComponent
            let descriptor = openDirectory(parent, blocked: scope.blocked)
            guard descriptor >= 0 else { return AskFileReadResponse(error: errno) }
            defer { close(descriptor) }
            let name = (request.path as NSString).lastPathComponent
            errno = 0
            let value = entry(name, parent: descriptor, path: request.path, scope: scope)
            return AskFileReadResponse(entries: value.map { [$0] } ?? [], error: value == nil && errno != 0 ? errno : nil)
        }
        let descriptor = openDirectory(request.path, blocked: scope.blocked)
        guard descriptor >= 0 else { return AskFileReadResponse(error: errno) }
        guard let directory = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            return AskFileReadResponse(error: code)
        }
        defer { closedir(directory) }
        var batch = AskFileReadResponse()
        var count = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        while count < max(0, request.limit) {
            // Also report progress when scanning filtered names, without sending unbounded frames.
            let now = ProcessInfo.processInfo.systemUptime
            if batch.entries.count >= 128 || now - lastProgress >= 0.1 {
                batch.more = true
                try emit(batch)
                batch = AskFileReadResponse()
                lastProgress = now
            }
            errno = 0
            guard let item = readdir(directory) else {
                batch.error = errno == 0 ? nil : errno
                return batch
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            let path = (request.path == "/" ? "" : request.path) + "/" + name
            // d_type is available without opening/statting the child. Filter protected paths first.
            guard scope.includes(path, isDirectory: item.pointee.d_type == DT_DIR) else { continue }
            if let mount = mounts.blocking(path) {
                batch.skippedMounts = (batch.skippedMounts ?? []) + [mount]
                continue
            }
            if let value = entry(name, parent: descriptor, path: path, scope: scope) {
                batch.entries.append(value)
                count += 1
            }
        }
        return batch
    }

    private static func entry(_ name: String, parent: Int32, path: String, scope: AskFileScope) -> AskFileCrawler.Entry? {
        guard !AskFileScope.isProtected(path, folders: scope.blocked) else { return nil }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        guard scope.includes(path, isDirectory: directory) else { return nil }
        // Symlinks remain leaf entries. Never resolve their targets while walking a tree.
        let kind: AskFileRecord.Kind = directory ? (AskFileCrawler.isPackage(path) ? .package : .folder) : .file
        return AskFileCrawler.Entry(path: path, kind: kind,
                                    modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)))
    }

    /// Opening ancestors with O_NOFOLLOW prevents an alias (or a replaced directory) bypassing the policy.
    private static func openDirectory(_ path: String, blocked: [String]) -> Int32 {
        guard path.hasPrefix("/"), AskFileScope.normalize(path) == path else { errno = EINVAL; return -1 }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        var current = ""
        for component in path.split(separator: "/") {
            guard descriptor >= 0 else { return -1 }
            current += "/" + component
            if AskFileScope.isProtected(current, folders: blocked) {
                close(descriptor)
                errno = EACCES
                return -1
            }
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            descriptor = next
            errno = code
        }
        return descriptor
    }

    /// Resolve configured aliases component by component, stopping before entering a protected target.
    static func resolve(_ path: String, blocked: [String], mounts: AskFileMounts = .current()) -> String {
        var pending = AskFileScope.normalize(path).split(separator: "/").map(String.init)
        var resolved = ""
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            let candidate = resolved + "/" + component
            if AskFileScope.isProtected(candidate, folders: blocked) || mounts.blocking(candidate) != nil {
                return candidate + (pending.isEmpty ? "" : "/" + pending.joined(separator: "/"))
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let count = readlink(candidate, &buffer, buffer.count)
            if count > 0 {
                links += 1
                guard links <= 40 else { return path }
                let target = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let full = AskFileScope.normalize(target.hasPrefix("/") ? target : resolved + "/" + target)
                pending = full.split(separator: "/").map(String.init) + pending
                resolved = ""
            } else { resolved = candidate }
        }
        return resolved.isEmpty ? "/" : resolved
    }
}
