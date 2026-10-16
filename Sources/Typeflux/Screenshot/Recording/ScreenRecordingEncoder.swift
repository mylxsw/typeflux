import Darwin
import Foundation
import TypefluxMediaProtocol

final class ScreenRecordingEncoder: @unchecked Sendable {
    static let shared = ScreenRecordingEncoder()
    private static let slots = AskToolPixelBudget(limit: 2)
    private let worker: MediaWorker
    init(worker: MediaWorker = .recordingExport) { self.worker = worker }

    func export(source: URL, destination: URL, format: ScreenRecordingFormat, trim: ScreenRecordingTrim,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let request = MediaRecordingExport(format: format == .gif ? .gif : .mp4, start: trim.start, end: trim.end)
        try request.validate()
        let ownership = try Ownership(slot: Self.slots.acquire(bytes: 1))
        let cancellation = AskSearchCancellation(), worker = self.worker
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let original = try ClipboardPlaybackSource(source, limit: MediaRecordingExport.inputBytes)
                let parent = source.deletingLastPathComponent().resolvingSymlinksInPath()
                guard destination.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
                      destination.isFileURL, destination.path.utf8.count <= 4096, !destination.path.utf8.contains(0), destination.lastPathComponent != source.lastPathComponent,
                      destination.pathExtension == request.format.rawValue else { throw MediaFailure.invalidProtocol }
                ownership.session = try ScreenRecordingEncodingOwnership(parent)
                try worker.owned(id: request.id, retaining: ownership, isCancelled: { cancellation.isCancelled }) { lease, executable, timeout, run, cancelled in
                    try Self.check(cancelled)
                    let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard parentFD >= 0 else { throw MediaFailure.unavailable }
                    defer { close(parentFD) }
                    var parentInfo = stat()
                    guard fstat(parentFD, &parentInfo) == 0 else { throw MediaFailure.unavailable }
                    let entries = try Self.entries(parent)
                    guard entries.filter({ $0.hasPrefix(".encoding-") }).count < 4,
                          !FileManager.default.fileExists(atPath: destination.path) else { throw MediaFailure.unavailable }
                    let directory = parent.appendingPathComponent(".encoding-" + request.id.uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    // Deliberately NOT lease.directory: failed or unacknowledged production stays recoverable.
                    let encoded = try JSONEncoder().encode(request)
                    try encoded.write(to: directory.appendingPathComponent("request.json"), options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("request.json").path)
                    try original.check()
                    try MediaWorker.copy(.file(source), to: directory.appendingPathComponent("input.mov"), limit: MediaRecordingExport.inputBytes, cancelled: cancelled)
                    try original.check()
                    let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw MediaFailure.unavailable }
                    defer { close(fd) }
                    let stream = Stream(request: request, progress: progress)
                    let process = ManagedProcess.Request(executable: executable.path, arguments: ["--recording-export"],
                        environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], directoryDescriptor: fd,
                        timeout: timeout, outputLimit: MediaRecordingExport.streamBytes, stopOnOutputLimit: true,
                        preserveWhitespace: true, onStarted: { lease.started() }, stdin: encoded, stderrLimit: 1024,
                        onOutput: { stream.accept($0) }, onReaped: { lease.reaped() })
                    do {
                    let result: ManagedProcess.Result
                    do { result = try run(process, { cancelled() || stream.invalid }) }
                    catch {
                        lease.infrastructureFailed = true
                        let code = error as NSError
                        lease.configurationFailure = code.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(ENOENT), Int(ENOEXEC)].contains(code.code)
                        throw error
                    }
                    try Self.check(cancelled)
                    stream.accept(result.stdout)
                    guard result.termination == .exited(0), !result.outputTruncated, !stream.invalid, stream.isComplete(result.stdout) else {
                        lease.infrastructureFailed = true; throw MediaFailure.invalidProtocol
                    }
                    // A valid failed terminal is a controlled job refusal, not a crashed service.
                    // Its files remain unconfirmed: even known failure may have produced partial bytes.
                    if stream.requestFailed { throw Failure.unconfirmed }
                    guard let bytes = stream.completedBytes else { lease.infrastructureFailed = true; throw MediaFailure.invalidProtocol }
                    try original.check()
                    do { try Self.validateOutput(request, bytes: bytes, directory: fd) }
                    catch {
                        // Missing or inconsistent promised output is a protocol fault. Applying local
                        // permissions is host filesystem work and must not blame the decoder.
                        if (error as? MediaFailure) != .unavailable { lease.infrastructureFailed = true }
                        throw error
                    }
                    try Self.check(cancelled)
                    var currentParent = stat()
                    guard lstat(parent.path, &currentParent) == 0, currentParent.st_dev == parentInfo.st_dev,
                          currentParent.st_ino == parentInfo.st_ino else { throw MediaFailure.unavailable }
                    // Exclusive transfer inside the retained session; this is not user-destination publication.
                    guard renameatx_np(fd, request.outputName, parentFD, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw MediaFailure.unavailable }
                    lease.directory = directory // Only known, validated transfer permits private-input cleanup.
                    } catch {
                        if cancelled() { throw CancellationError() }
                        throw Failure.unconfirmed
                    }
                }
            }.value
            try Task.checkCancellation()
        } onCancel: { cancellation.cancel() }
    }
    enum Failure: LocalizedError {
        case unconfirmed
        var errorDescription: String? { L("recording.encodingUnconfirmed") }
    }
    private static func entries(_ directory: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]) else { throw MediaFailure.unavailable }
        var names: [String] = []
        for case let url as URL in enumerator {
            guard names.count < 1024 else { throw MediaFailure.tooLarge }
            names.append(url.lastPathComponent)
        }
        return names
    }
    private static func check(_ cancelled: () -> Bool) throws { if cancelled() { throw CancellationError() } }
    private static func validateOutput(_ request: MediaRecordingExport, bytes: Int, directory: Int32) throws {
        let fd = openat(directory, request.outputName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MediaFailure.unreadable }
        defer { close(fd) }
        var info = stat(), header = [UInt8](repeating: 0, count: 12)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == bytes, bytes <= request.outputLimit, read(fd, &header, header.count) == 12 else { throw MediaFailure.invalidProtocol }
        let signature = request.format == .gif ? (Array(header.prefix(6)) == Array("GIF89a".utf8) || Array(header.prefix(6)) == Array("GIF87a".utf8)) : Array(header[4..<8]) == Array("ftyp".utf8)
        guard signature else { throw MediaFailure.invalidProtocol }
        guard fchmod(fd, 0o600) == 0 else { throw MediaFailure.unavailable }
    }
    private final class Ownership: @unchecked Sendable {
        let slot: AskToolPixelBudget.Lease
        var session: ScreenRecordingEncodingOwnership?
        init(slot: AskToolPixelBudget.Lease) { self.slot = slot }
        deinit { session = nil; withExtendedLifetime(slot) {} }
    }
    /// ManagedProcess passes a bounded cumulative prefix. Parse only newly completed lines.
    final class Stream: @unchecked Sendable {
        private let lock = NSLock()
        private let request: MediaRecordingExport
        private let progress: @Sendable (Double) -> Void
        private var consumed = 0, sequence = 0, last = 0.0, terminal = false, failed = false
        private var bytes: Int?
        init(request: MediaRecordingExport, progress: @escaping @Sendable (Double) -> Void) { self.request = request; self.progress = progress }
        var invalid: Bool { lock.withLock { failed } }
        var completedBytes: Int? { lock.withLock { bytes } }
        var requestFailed: Bool { lock.withLock { terminal && bytes == nil } }
        func isComplete(_ value: String) -> Bool { lock.withLock { terminal && consumed == value.utf8.count } }
        func accept(_ value: String) {
            lock.withLock {
                guard !failed else { return }
                let data = Data(value.utf8)
                guard data.count <= MediaRecordingExport.streamBytes, data.count >= consumed else { failed = true; return }
                var offset = consumed
                do {
                    while let end = data[offset...].firstIndex(of: 10) {
                        guard !terminal, end - offset <= 1024 else { throw MediaFailure.invalidProtocol }
                        let event = try JSONDecoder().decode(MediaRecordingExportEvent.self, from: data[offset..<end])
                        try event.validate(for: request, sequence: sequence + 1)
                        guard event.progress >= last else { throw MediaFailure.invalidProtocol }
                        sequence += 1; last = event.progress; terminal = event.kind != .progress
                        bytes = event.kind == .completed ? event.bytes : nil
                        progress(last)
                        offset = end + 1; consumed = offset
                    }
                    guard data.count - consumed <= 1024 else { throw MediaFailure.invalidProtocol }
                } catch { failed = true }
            }
        }
    }
}

/// Explicit discard waits for BOTH host work and child collection; it never kills a producer's files.
final class ScreenRecordingEncodingOwnership: @unchecked Sendable {
    private struct Entry { let id: UUID; var discard: (() -> Void)? }
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private let key: String
    private let id = UUID()
    init(_ directory: URL) throws {
        key = directory.resolvingSymlinksInPath().path
        try Self.lock.withLock {
            guard Self.entries[key] == nil else { throw MediaFailure.unavailable }
            Self.entries[key] = Entry(id: id)
        }
    }
    deinit {
        let action: (() -> Void)? = Self.lock.withLock {
            guard Self.entries[key]?.id == id else { return nil }
            let entry = Self.entries.removeValue(forKey: key)
            return entry?.discard
        }
        action?()
    }
    static func discard(_ directory: URL, action: @escaping () -> Void) {
        let key = directory.resolvingSymlinksInPath().path
        var snapshot = stat()
        guard lstat(key, &snapshot) == 0, snapshot.st_mode & S_IFMT == S_IFDIR else { return }
        let device = snapshot.st_dev, inode = snapshot.st_ino
        let guarded = {
            var current = stat()
            if lstat(key, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
               current.st_dev == device, current.st_ino == inode { action() }
        }
        let deferred = lock.withLock {
            guard entries[key] != nil else { return false }
            entries[key]?.discard = guarded; return true
        }
        if !deferred { guarded() }
    }
}
