import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative host operations. User code never receives these descriptors.
/// The threat model includes hostile sandbox programs, not other unsandboxed apps
/// running as the same macOS user (which can also modify Typeflux itself).
final class AskSecureDirectory {
    let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    static func failure(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "Sandbox storage: \(operation) failed (\(errno))."]
        )
    }

    static func openRoot(_ url: URL, create: Bool = true, privateRoot: Bool = true) throws -> AskSecureDirectory {
        // Only normalize OS-owned aliases; never resolve attacker-controlled links.
        var path = url.path
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            path = "/private" + path
        }
        guard path.hasPrefix("/") else { throw failure("absolute path required") }
        var directory = AskSecureDirectory(descriptor: open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        guard directory.descriptor >= 0 else { throw failure("open root") }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw failure("private root required") }
        for (index, name) in components.enumerated() {
            directory = try directory.child(
                name,
                create: create,
                privateDirectory: privateRoot && index == components.count - 1
            )
        }
        return directory
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    func child(_ name: String, create: Bool = false, privateDirectory: Bool = false) throws -> AskSecureDirectory {
        guard Self.validName(name) else { throw Self.failure("invalid component") }
        if create, mkdirat(descriptor, name, 0o700) != 0, errno != EEXIST {
            throw Self.failure("mkdirat")
        }
        let fileDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fileDescriptor >= 0 else { throw Self.failure("openat directory") }
        let child = AskSecureDirectory(descriptor: fileDescriptor)
        if privateDirectory {
            var info = stat()
            guard fstat(fileDescriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                throw Self.failure("unsafe directory permissions")
            }
        }
        return child
    }

    var url: URL {
        get throws {
            var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { throw Self.failure("get descriptor path") }
            return URL(fileURLWithPath: String(cString: bytes), isDirectory: true)
        }
    }

    func lock() throws {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure("workspace already in use") }
    }

    func createFile(_ name: String, data: Data) throws {
        guard Self.validName(name) else { throw Self.failure("invalid filename") }
        let fileDescriptor = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fileDescriptor >= 0 else { throw Self.failure("create script") }
        defer { close(fileDescriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw Self.failure("write script") }
                offset += count
            }
        }
    }

    func readFile(_ relative: String, limit: Int) throws -> Data {
        guard limit >= 0, limit < Int.max else { throw Self.failure("invalid artifact limit") }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relative.hasPrefix("/"), parts.allSatisfy(Self.validName), let name = parts.last else {
            throw Self.failure("invalid artifact path")
        }
        var parent = self
        for part in parts.dropLast() {
            parent = try parent.child(part)
        }
        let fileDescriptor = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fileDescriptor >= 0 else { throw Self.failure("open artifact") }
        defer { close(fileDescriptor) }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size <= limit else { throw Self.failure("unsafe or oversized artifact") }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while result.count <= limit {
            let count = read(fileDescriptor, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw Self.failure("read artifact") }
            if count == 0 {
                return result
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        throw Self.failure("artifact grew beyond limit")
    }

    func entries(limit: Int = 4096) -> [String] {
        // openat gives readdir its own offset; dup would share the directory offset.
        let fileDescriptor = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { return [] }
        guard let stream = fdopendir(fileDescriptor) else { close(fileDescriptor); return [] }
        defer { closedir(stream) }
        var names: [String] = []
        while names.count < limit, let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    func snapshot() -> [String: (Date, Int)] {
        var result: [String: (Date, Int)] = [:]
        var budget = 4096
        func visit(_ directory: AskSecureDirectory, prefix: String, depth: Int) {
            guard depth < 16, budget > 0 else { return }
            for name in directory.entries(limit: budget) where !name.hasPrefix(".") {
                guard budget > 0 else { break }
                budget -= 1
                var info = stat()
                guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let relative = prefix + name
                if info.st_mode & S_IFMT == S_IFDIR, let child = try? directory.child(name) {
                    visit(child, prefix: relative + "/", depth: depth + 1)
                } else if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 {
                    let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
                    result[relative] = (Date(timeIntervalSince1970: modified), Int(info.st_size))
                }
            }
        }
        visit(self, prefix: "", depth: 0)
        return result
    }

    /// Never follows a link during cleanup, including a link substituted mid-walk.
    func remove(_ name: String, depth: Int = 0) throws {
        guard Self.validName(name), depth < 64 else { throw Self.failure("invalid cleanup path") }
        if let child = try? child(name) {
            for entry in child.entries() {
                try child.remove(entry, depth: depth + 1)
            }
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw Self.failure("remove directory") }
        } else if unlinkat(descriptor, name, 0) != 0, errno != ENOENT {
            throw Self.failure("unlink entry")
        }
    }

    static func sessionName(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
