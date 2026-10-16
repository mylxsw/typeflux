import Darwin
import Foundation

/// A single explicit publication. The receipt is retained beside the generated output
/// on failure; it is not permission to retry the encoder or a possibly committed rename.
final class ScreenRecordingPublication: @unchecked Sendable {
    static let maximumBytes = 8 * 1024 * 1024 * 1024
    private static let slots = AskToolPixelBudget(limit: 2)
    struct Receipt: Codable, Equatable {
        enum Phase: String, Codable { case preparing, prepared, committing, published, unknown, cancelled }
        var id: UUID
        var source: String
        var destination: String
        var bytes: Int
        var phase: Phase
    }
    enum Failure: Error, LocalizedError {
        case unavailable, changed, unknown, duplicate
        var errorDescription: String? {
            switch self {
            case .unknown: L("recording.publicationUnknown")
            default: L("recording.publicationUnavailable")
            }
        }
    }
    typealias Rename = @Sendable (Int32, String, String, Bool) throws -> Void
    let destination: URL
    let receiptURL: URL
    let mayDiscardSession: Bool
    private let parent: AskSecureDirectory
    private let journal: AskSecureDirectory
    private let source: ClipboardPlaybackSource
    private let stage: String
    private let target: String
    private let directory: URL
    private let expected: Identity?
    private var staged: Identity?
    private let slot: AskToolPixelBudget.Lease
    private let rename: Rename
    private let lock = NSLock()
    private var attempted = false
    private var preserveStage = false
    private var receipt: Receipt
    private struct Identity: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, modified: Int, changed: Int, modifiedNanos: Int, changedNanos: Int
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modified = value.st_mtimespec.tv_sec; changed = value.st_ctimespec.tv_sec
            modifiedNanos = value.st_mtimespec.tv_nsec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    static func prepare(source: URL, directory: URL, format: ScreenRecordingFormat, name: String?,
                        destination: URL?, protectedRoot: URL,
                        rename: @escaping Rename = { try ScreenRecordingPublication.renameFile($0, $1, $2, $3) },
                        beforeCopy: @escaping @Sendable () -> Void = {}) async throws -> ScreenRecordingPublication {
        try Task.checkCancellation()
        let slot = try slots.acquire(bytes: 1), cancelled = AskSearchCancellation()
        return try await withTaskCancellationHandler {
            let result = try await Task.detached(priority: .utility) {
                beforeCopy()
                if cancelled.isCancelled { throw CancellationError() }
                return try Self(source: source, directory: directory, format: format, name: name,
                         destination: destination, protectedRoot: protectedRoot, slot: slot, rename: rename,
                         cancelled: { cancelled.isCancelled })
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancelled.cancel() }
    }
    private init(source url: URL, directory: URL, format: ScreenRecordingFormat, name: String?, destination chosen: URL?,
                 protectedRoot: URL, slot: AskToolPixelBudget.Lease, rename: @escaping Rename,
                 cancelled: () -> Bool) throws {
        guard directory.isFileURL, directory.path.utf8.count <= 4096 else { throw Failure.unavailable }
        source = try ClipboardPlaybackSource(url, limit: Self.maximumBytes)
        self.slot = slot; self.rename = rename
        parent = try AskSecureDirectory.openRoot(directory, create: true, privateRoot: false)
        self.directory = try parent.url
        let root = try AskSecureDirectory.openRoot(protectedRoot, create: true, privateRoot: false).url.path
        guard self.directory.path != root, !self.directory.path.hasPrefix(root + "/") else { throw Failure.unavailable }
        journal = try AskSecureDirectory.openRoot(url.deletingLastPathComponent(), create: false, privateRoot: false)
        let entries = journal.entries(limit: 1025)
        guard entries.count <= 1024, entries.filter({ $0.hasPrefix(".publication-") }).count < 16 else { throw Failure.unavailable }
        mayDiscardSession = entries.contains(url.lastPathComponent) && entries.contains("source.mov") && entries.contains("options.json")
            && entries.allSatisfy { ["source.mov", "options.json", url.lastPathComponent].contains($0) }
        if let chosen {
            guard chosen.isFileURL, chosen.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  AskSecureDirectory.validName(chosen.lastPathComponent), chosen.lastPathComponent.utf8.count <= 255
            else { throw Failure.unavailable }
            target = chosen.lastPathComponent
        } else {
            let base = ScreenRecordingLayout.fileName(name ?? "Typeflux Recording")
            var candidate: String?
            for suffix in 0..<10_000 {
                let name = base + (suffix == 0 ? "" : " (\(suffix + 1))") + "." + format.rawValue
                if try Self.identity(parent, name) == nil { candidate = name; break }
            }
            guard let candidate else { throw Failure.unavailable }; target = candidate
        }
        expected = try Self.identity(parent, target)
        self.destination = self.directory.appendingPathComponent(target)
        let id = UUID(); stage = ".typeflux-recording-" + id.uuidString
        receiptURL = url.deletingLastPathComponent().appendingPathComponent(".publication-" + id.uuidString + ".json")
        receipt = Receipt(id: id, source: url.lastPathComponent, destination: self.destination.path, bytes: Int(source.bytes), phase: .preparing)
        try journal.createFile(receiptURL.lastPathComponent, data: JSONEncoder().encode(receipt))
        let output = openat(parent.descriptor, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.unavailable }
        var complete = false
        defer { close(output); if !complete { try? parent.remove(stage) } }
        let input = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw Failure.unavailable }; defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == source.bytes, info.st_dev == source.device, info.st_ino == source.inode,
              info.st_mtimespec.tv_sec == source.modified, info.st_mtimespec.tv_nsec == source.modifiedNanos,
              info.st_ctimespec.tv_sec == source.changed, info.st_ctimespec.tv_nsec == source.changedNanos else { throw Failure.changed }
        let before = Identity(info)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024), total = 0
        while true {
            if cancelled() { throw CancellationError() }
            let count = read(input, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unavailable }
            if count == 0 { break }
            guard count <= Self.maximumBytes - total else { throw Failure.unavailable }; total += count
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw Failure.unavailable }; offset += written
                }
            }
        }
        guard total == source.bytes, fstat(input, &info) == 0, Identity(info) == before else { throw Failure.changed }
        try source.check()
        guard let staged = try Self.identity(parent, stage) else { throw Failure.changed }; self.staged = staged
        receipt.phase = .prepared
        try Self.write(receipt, in: journal, name: receiptURL.lastPathComponent)
        complete = true
    }
    /// Small descriptor-relative commit, no IPC or suspension after authorization.
    @MainActor func commit(authorize: () -> Bool) throws -> URL {
        guard lock.withLock({ if attempted { return false }; attempted = true; return true }) else { throw Failure.duplicate }
        try Task.checkCancellation()
        try source.check()
        guard let staged, try parent.url == directory, try Self.identity(parent, stage) == staged,
              try Self.identity(parent, target) == expected else { throw Failure.changed }
        receipt.phase = .committing
        try Self.write(receipt, in: journal, name: receiptURL.lastPathComponent)
        guard authorize(), !Task.isCancelled else {
            receipt.phase = .cancelled; try? Self.write(receipt, in: journal, name: receiptURL.lastPathComponent)
            throw CancellationError()
        }
        preserveStage = true
        do { try rename(parent.descriptor, stage, target, expected != nil) }
        catch {
            receipt.phase = .unknown; try? Self.write(receipt, in: journal, name: receiptURL.lastPathComponent)
            throw Failure.unknown
        }
        receipt.phase = .published
        // Acknowledgement persistence failure cannot undo a successful rename.
        try? Self.write(receipt, in: journal, name: receiptURL.lastPathComponent)
        return destination
    }
    static func renameFile(_ descriptor: Int32, _ source: String, _ destination: String, _ replace: Bool) throws {
        guard renameatx_np(descriptor, source, descriptor, destination, replace ? 0 : UInt32(RENAME_EXCL)) == 0
        else { throw Failure.unknown }
    }
    private static func identity(_ parent: AskSecureDirectory, _ name: String) throws -> Identity? {
        var value = stat()
        if fstatat(parent.descriptor, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw Failure.unavailable
        }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else { throw Failure.changed }
        return Identity(value)
    }
    private static func write(_ value: Receipt, in directory: AskSecureDirectory, name: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8192 else { throw Failure.unavailable }
        let temporary = name + ".pending"
        try directory.createFile(temporary, data: data)
        defer { try? directory.remove(temporary) }
        guard renameat(directory.descriptor, temporary, directory.descriptor, name) == 0 else { throw Failure.unavailable }
    }
    deinit { if !preserveStage { try? parent.remove(stage) }; withExtendedLifetime(slot) {} }
}

/// Poll a single latest value; native callbacks cannot enqueue unbounded MainActor tasks.
final class ScreenRecordingProgressBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func offer(_ next: Double) { lock.withLock { if next.isFinite { value = max(value, min(1, max(0, next))) } } }
    var latest: Double { lock.withLock { value } }
}
