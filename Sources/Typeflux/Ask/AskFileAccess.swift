import CryptoKit
import Darwin
import Foundation

/// Descriptor operations follow AskSecureDirectory's threat model. Arbitrary
/// uncooperative same-user writers are outside the check/rename guarantee.
final class AskFileAccess {
    struct Location {
        let root: String
        let parts: [String]
        var path: String {
            root + (root == "/" ? "" : "/") + parts.joined(separator: "/")
        }
    }

    static func error(_ message: String) -> AskLocalError {
        .message(message)
    }

    static var conflict: AskLocalError {
        error("The file or folder changed. Read the file again before continuing.")
    }

    static var denied: AskLocalError {
        error("Cannot securely access this path. Check the folder grant and remove links in the path.")
    }

    static func location(_ raw: String, roots: [String]) throws -> Location {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !raw.isEmpty, raw.utf8.count <= 1024, !roots.isEmpty,
              !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !expanded.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw denied }
        var checked = expanded
        if checked.hasPrefix("/") {
            checked.removeFirst()
        } else if checked.hasPrefix("./") {
            checked.removeFirst(2)
        }
        if checked != ".", !checked.isEmpty {
            guard checked.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ AskSecureDirectory.validName(String($0)) }) else { throw denied }
        }
        let normalized = roots.map(AskProjectFileAccess.normalizedRoot)
        let absolute = expanded.hasPrefix("/") ? AskProjectFileAccess
            .normalizedRoot(expanded) : normalized[0] + "/" + expanded
        let path = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard let root = normalized.filter({ path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") })
            .max(by: { $0.utf8.count < $1.utf8.count }) else { throw denied }
        let relative = path == root ? "" : String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        let parts = relative.isEmpty ? [] : relative.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count <= 64,
              parts.allSatisfy({ AskSecureDirectory.validName($0) && $0.utf8.count <= Int(MAXNAMLEN) })
        else { throw denied }
        return Location(root: root, parts: parts)
    }

    static func openRoot(_ path: String) throws -> AskSecureDirectory {
        do {
            if path == "/" {
                let descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw denied }
                return AskSecureDirectory(descriptor: descriptor)
            }
            return try AskSecureDirectory.openRoot(URL(fileURLWithPath: path), create: false, privateRoot: false)
        } catch { throw denied }
    }

    static func stamp(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):" +
            "\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode):\(info.st_nlink)"
    }

    static func info(_ descriptor: Int32) throws -> stat {
        var result = stat()
        guard fstat(descriptor, &result) == 0 else { throw denied }
        return result
    }

    static func identity(_ descriptor: Int32) throws -> String {
        let info = try info(descriptor)
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func version(_ info: stat) -> String {
        digest(Data(stamp(info).utf8))
    }

    let location: Location
    let root: AskSecureDirectory
    let rootIdentity: String
    let parent: AskSecureDirectory
    let parentIdentity: String
    let descriptor: Int32
    let initial: stat?
    let hooks: AskFileTools.Hooks
    var name: String {
        location.parts.last ?? "."
    }

    var version: String {
        initial.map(Self.version) ?? "missing"
    }

    init(_ location: Location, directory: Bool = false, createParents: Bool = false,
         allowMissing: Bool = false, hooks: AskFileTools.Hooks = .init()) throws {
        self.location = location
        self.hooks = hooks
        root = try Self.openRoot(location.root)
        rootIdentity = try Self.identity(root.descriptor)
        var walked = root
        for part in location.parts.dropLast() {
            try Task.checkCancellation()
            walked = try walked.child(part, create: createParents)
        }
        parent = walked
        parentIdentity = try Self.identity(parent.descriptor)
        descriptor = openat(
            parent.descriptor,
            location.parts.last ?? ".",
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        )
        if descriptor < 0 {
            guard allowMissing, errno == ENOENT, !location.parts.isEmpty else { throw Self.denied }
            initial = nil
        } else {
            do {
                let value = try Self.info(descriptor)
                guard value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw Self.denied }
                initial = value
            } catch { close(descriptor); throw error }
        }
    }

    deinit {
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    /// Re-open from the grant, then re-walk. A pinned but renamed parent is insufficient.
    func revalidate(checkCancellation: Bool = true) throws {
        if checkCancellation {
            try Task.checkCancellation()
        }
        try hooks.validateGrant?()
        let currentRoot = try Self.openRoot(location.root)
        guard try Self.identity(currentRoot.descriptor) == rootIdentity else { throw Self.conflict }
        var current = currentRoot
        for part in location.parts.dropLast() {
            current = try current.child(part)
        }
        guard try Self.identity(current.descriptor) == parentIdentity else { throw Self.conflict }
        var linked = stat()
        let result = fstatat(current.descriptor, name, &linked, AT_SYMLINK_NOFOLLOW)
        if let initial {
            guard result == 0, Self.stamp(linked) == Self.stamp(initial),
                  try Self.stamp(Self.info(descriptor)) == Self.stamp(initial) else { throw Self.conflict }
        } else {
            guard result != 0, errno == ENOENT else { throw Self.conflict }
        }
    }

    func boundedData(limit: Int, budget: Int? = nil) throws -> Data {
        guard let initial,
              initial.st_size <= limit else { throw Self.error("File is too large. Use a smaller-file workflow.") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        let ceiling = min(limit, budget ?? limit)
        var position = 0
        while true {
            try Task.checkCancellation()
            try hooks.onEvent?("read")
            let count = pread(descriptor, &buffer, min(buffer.count, ceiling + 1 - data.count), off_t(position))
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw Self.denied }
            if count == 0 {
                break
            }
            try hooks.onBytes?(count)
            guard count <= ceiling - data.count else { throw Self.error("File grew beyond the read budget.") }
            data.append(contentsOf: buffer.prefix(count)); position += count
        }
        try revalidate()
        return data
    }

    /// fdopendir owns this descriptor, with an independent directory offset.
    static func enumerate(_ directory: Int32, visit: (String) throws -> Bool) throws {
        let duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0 else { throw denied }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw denied }
        defer { closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw denied }
                return
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." {
                continue
            }
            if try !visit(name) {
                return
            }
        }
    }
}
