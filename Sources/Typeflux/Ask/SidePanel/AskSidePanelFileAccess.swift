import Darwin
import Foundation

/// Which files a file tab may open: only files inside the conversation's workspace or a
/// folder the user granted to the conversation. Paths are normalized, `..` is refused,
/// and every component is opened without following links, so a link cannot lead out.
enum AskSidePanelFileAccess {
    /// A file proven to sit under one of the allowed roots.
    struct Target: Equatable, Hashable, Sendable {
        let root: String
        let relativePath: String
        var path: String { root + (root == "/" ? "" : "/") + relativePath }
        var url: URL { URL(fileURLWithPath: path) }
        var name: String { (relativePath as NSString).lastPathComponent }
    }

    enum AccessError: LocalizedError, Equatable {
        case denied, notAFile, tooLarge
        var errorDescription: String? {
            switch self {
            case .denied: L("ask.sidePanel.file.denied")
            case .notAFile: L("ask.sidePanel.file.missing")
            case .tooLarge: L("ask.sidePanel.file.tooLarge")
            }
        }
    }

    /// Resolves a path relative to the workspace (`outputs/report.html`) or an absolute path
    /// under the workspace or a granted folder. The root itself is never a file target.
    static func resolve(_ path: String, workspaceRoot: URL, grantedRoots: [String] = []) throws -> Target {
        let roots = [workspaceRoot.path] + grantedRoots
        guard let location = try? AskFileAccess.location(path, roots: roots), !location.parts.isEmpty else {
            throw AccessError.denied
        }
        let target = Target(root: location.root, relativePath: location.parts.joined(separator: "/"))
        try check(target, roots: roots)
        return target
    }

    /// The target's root must still be allowed (a grant can be revoked), and the file must
    /// still be a regular file reached without links.
    static func check(_ target: Target, roots: [String]) throws {
        _ = try read(target, roots: roots, limit: 0, clip: true)
    }

    /// Reads at most `limit` bytes. Larger files throw `tooLarge`, or with `clip` return their
    /// first `limit` bytes and `true`.
    static func read(_ target: Target, roots: [String], limit: Int) throws -> Data {
        try read(target, roots: roots, limit: limit, clip: false).data
    }

    static func read(_ target: Target, roots: [String], limit: Int,
                     clip: Bool) throws -> (data: Data, clipped: Bool) {
        guard roots.map(AskProjectFileAccess.normalizedRoot).contains(target.root) else { throw AccessError.denied }
        let parts = target.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(AskSecureDirectory.validName) else { throw AccessError.denied }
        let directory: AskSecureDirectory
        do {
            var parent = try AskFileAccess.openRoot(target.root)
            for part in parts.dropLast() { parent = try parent.child(part) }
            directory = parent
        } catch { throw AccessError.denied }
        let descriptor = openat(directory.descriptor, parts[parts.count - 1],
                                O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw errno == ELOOP ? AccessError.denied : AccessError.notAFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AccessError.notAFile }
        guard clip || Int64(info.st_size) <= Int64(limit) else { throw AccessError.tooLarge }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while result.count < limit || (!clip && result.count == limit) {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit + 1 - result.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AccessError.notAFile }
            if count == 0 { return (result, false) }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard clip else { throw AccessError.tooLarge }
        return (result.prefix(limit), result.count > limit || Int64(info.st_size) > Int64(limit))
    }
}
