import Darwin
import Foundation

/// Retained by the state owner, not by a request or a window. A timeout does not
/// release ownership while an admitted model/tool operation may still be running.
final class AskConversationDirectoryLease: Sendable {
    static let filename = ".conversation-owner.lock"
    private let descriptor: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(Self.filename)
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1 else {
            close(descriptor)
            throw POSIXError(.EINVAL)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { throw AskConversationOwnershipError.inUse }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        // Never unlink the lock file: another process may already have it open.
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

enum AskConversationOwnershipError: LocalizedError, Equatable {
    case inUse

    var errorDescription: String? { L("ask.storage.inUse") }
}
