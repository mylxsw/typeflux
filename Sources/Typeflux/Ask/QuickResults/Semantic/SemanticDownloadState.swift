import Darwin
import Foundation

/// Private, descriptor-relative state, held exclusively until the transfer has joined.
final class SemanticDownloadState {
    struct Identity: Codable, Equatable {
        let url: URL
        let bytes: Int64
        let sha256: String
    }
    private struct Metadata: Codable {
        let identity: Identity
        let etag: String?
    }
    let directory: AskSecureDirectory
    let identity: Identity
    let file: FileHandle
    private(set) var etag: String?
    private(set) var received: Int64

    init(root: URL, identity: Identity) throws {
        guard identity.bytes > 0 else { throw URLError(.badServerResponse) }
        self.identity = identity
        let root = try AskSecureDirectory.openRoot(root)
        let key = AskSecureDirectory.sessionName("\(identity.url.absoluteString)\n\(identity.bytes)\n\(identity.sha256)")
        directory = try root.child(key, create: true, privateDirectory: true)
        try directory.lock()
        let descriptor = openat(directory.descriptor, "payload",
                                O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AskSecureDirectory.failure("open download") }
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw AskSecureDirectory.failure("unsafe download")
        }
        received = info.st_size
        let data = try? directory.readFile("metadata.json", limit: 16 * 1024)
        let metadata = data.flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
        etag = metadata?.etag
        if metadata?.identity != identity || received > identity.bytes || (received > 0 && etag == nil) {
            try reset(etag: nil)
        }
        try file.seekToEnd()
    }

    func reset(etag: String?) throws {
        try file.truncate(atOffset: 0)
        try file.seek(toOffset: 0)
        received = 0
        self.etag = etag
        try saveMetadata()
    }

    private func saveMetadata() throws {
        let temporary = UUID().uuidString + ".json"
        defer { try? directory.remove(temporary) }
        try directory.createFile(temporary, data: JSONEncoder().encode(Metadata(identity: identity, etag: etag)))
        guard renameat(directory.descriptor, temporary, directory.descriptor, "metadata.json") == 0 else {
            throw AskSecureDirectory.failure("save download metadata")
        }
    }

    func append(_ data: Data) throws {
        guard Int64(data.count) <= identity.bytes - received else {
            try reset(etag: nil)
            throw URLError(.dataLengthExceedsMaximum)
        }
        try file.write(contentsOf: data)
        received += Int64(data.count)
    }

    func complete(cancelled: () -> Bool) throws -> URL {
        try file.synchronize()
        let base = try directory.url
        do {
            try file.seek(toOffset: 0)
            try SemanticModel.verify(file, bytes: identity.bytes, sha256: identity.sha256, cancelled: cancelled)
            // The directory entry must still name the descriptor whose bytes were verified.
            var opened = stat(), named = stat()
            guard fstat(file.fileDescriptor, &opened) == 0,
                  fstatat(directory.descriptor, "payload", &named, AT_SYMLINK_NOFOLLOW) == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
                  named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1 else {
                throw URLError(.cannotOpenFile)
            }
        } catch {
            if !cancelled() { try reset(etag: nil) }
            throw error
        }
        if cancelled() { throw CancellationError() }
        let name = UUID().uuidString + ".verified"
        guard renameat(directory.descriptor, "payload", directory.descriptor, name) == 0 else {
            throw AskSecureDirectory.failure("finish download")
        }
        var published = stat(), opened = stat()
        guard fstat(file.fileDescriptor, &opened) == 0,
              fstatat(directory.descriptor, name, &published, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == published.st_dev, opened.st_ino == published.st_ino,
              published.st_mode & S_IFMT == S_IFREG, published.st_nlink == 1 else {
            try? directory.remove(name)
            throw URLError(.cannotOpenFile)
        }
        try? directory.remove("metadata.json")
        return base.appendingPathComponent(name)
    }
}
