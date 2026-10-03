import Darwin
import Foundation

enum AskProjectError: Error, LocalizedError, Equatable {
    case denied, invalidPath, conflict, binary, tooLarge, invalid, unavailable

    var errorDescription: String? {
        L("ask.project.error." + String(describing: self))
    }
}

/// Source files are only ever opened read-only. Every component is walked with
/// O_NOFOLLOW, including the authorized root. No realpath-then-open boundary.
struct AskProjectFileAccess {
    static let maximumReadBytes = 16 * 1024 * 1024
    let directory: AskSecureDirectory
    var afterOpen: (() throws -> Void)?

    struct Snapshot: Equatable {
        var data: Data?
        var version: String
    }

    static func normalizedRoot(_ path: String) -> String {
        var value = (path as NSString).expandingTildeInPath
        for alias in ["/tmp", "/var", "/etc"] where value == alias || value.hasPrefix(alias + "/") {
            value = "/private" + value
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    static func parts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count < Int(MAXPATHLEN), parts.count <= 64,
              parts.allSatisfy({ AskSecureDirectory.validName($0) && $0.utf8.count <= Int(MAXNAMLEN) }),
              !parts.contains(where: { $0.lowercased() == ".git" }),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AskProjectError.invalidPath
        }
        return parts
    }

    static func identity(_ directory: AskSecureDirectory) throws -> String {
        var info = stat()
        guard fstat(directory.descriptor, &info) == 0 else { throw AskProjectError.denied }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private static func stamp(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):" +
            "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode):\(info.st_nlink)"
    }

    func snapshot(_ path: String) throws -> Snapshot {
        let parts = try Self.parts(path)
        var parent = directory
        for part in parts.dropLast() {
            do { parent = try parent.child(part) } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
                return .init(data: nil, version: "missing")
            }
        }
        let name = parts.last!
        let descriptor = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT {
            return .init(data: nil, version: "missing")
        }
        guard descriptor >= 0 else { throw AskProjectError.denied }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw AskProjectError.denied
        }
        guard before.st_size <= Self.maximumReadBytes else { throw AskProjectError.tooLarge }
        try afterOpen?()
        let data = try Self.read(descriptor)
        var after = stat(), linked = stat()
        guard fstat(descriptor, &after) == 0, Self.stamp(before) == Self.stamp(after) else {
            throw AskProjectError.conflict
        }
        // Re-walk from the pinned root to detect a parent renamed/replaced during
        // the read. Even a failed revalidation never releases the captured bytes.
        var currentParent = directory
        for part in parts.dropLast() {
            currentParent = try currentParent.child(part)
        }
        guard fstatat(currentParent.descriptor, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              Self.stamp(after) == Self.stamp(linked) else { throw AskProjectError.conflict }
        return .init(data: data, version: AskToolPolicy.digest(Self.stamp(after) + ":" + AskToolPolicy.digest(data)))
    }

    static func text(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw AskProjectError.binary }
        return text
    }

    private static func read(_ descriptor: Int32) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw AskProjectError.denied }
            if count == 0 {
                return data
            }
            guard count <= maximumReadBytes - data.count else { throw AskProjectError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    /// A grapheme can contain megabytes of combining marks. Bound bytes, then
    /// trim at a valid UTF-8 boundary without introducing replacement text.
    static func preview(_ text: String, maximumBytes: Int = 24000) -> String {
        var data = Data(text.utf8.prefix(max(0, maximumBytes)))
        while !data.isEmpty {
            if let result = String(data: data, encoding: .utf8) {
                return result
            }
            data.removeLast()
        }
        return ""
    }

    func list(_ path: String) throws -> [String] {
        var target = directory
        if path != "." {
            for part in try Self.parts(path) {
                target = try target.child(part)
            }
        }
        return target.entries(limit: 502).filter { $0.lowercased() != ".git" }.sorted()
    }
}
