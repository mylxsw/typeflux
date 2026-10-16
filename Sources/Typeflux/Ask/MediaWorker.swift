import Darwin
import Foundation
import TypefluxMediaProtocol

/// A bounded, independent fault domain for disposable attachment decoders.
final class MediaWorker: @unchecked Sendable {
    static let shared = MediaWorker()
    enum Input { case file(URL), data(Data) }
    typealias Runner = @Sendable (ManagedProcess.Request, @escaping @Sendable () -> Bool) throws -> ManagedProcess.Result
    private let lock = NSLock()
    private var active: [UUID: MediaLease] = [:]
    private var disabled = false
    private var budget = ModuleRecoveryBudget()
    private let executable: URL
    private let timeout: TimeInterval
    private let run: Runner
    private let uptime: @Sendable () -> TimeInterval

    init(executable: URL = MediaWorker.helperURL, timeout: TimeInterval = 30,
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         run: @escaping Runner = { try ManagedProcess().runBlocking($0, isCancelled: $1) }) {
        self.executable = executable; self.timeout = timeout; self.uptime = uptime; self.run = run
    }

    static var helperURL: URL {
        helperURL(appExecutable: AskFileReader.executableURL)
    }

    static func helperURL(appExecutable binary: URL) -> URL {
        let directory = binary.deletingLastPathComponent()
        return (directory.lastPathComponent == "MacOS" && directory.deletingLastPathComponent().lastPathComponent == "Contents"
                ? directory.deletingLastPathComponent().appendingPathComponent("Helpers") : directory)
            .appendingPathComponent("TypefluxMediaHelper")
    }

    /// Synchronous only on the attachment batch's owned background task.
    func decode(_ operation: MediaRequest.Operation, input: Input,
                isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> MediaResponse {
        let id = UUID(), lease = MediaLease()
        try lock.withLock {
            guard !disabled, budget.permitsAttempt(at: uptime()), active.count < 2,
                  !isCancelled() else { throw MediaFailure.unavailable }
            active[id] = lease
        }
        lease.cleanup = { [self] in lock.withLock { active[id] = nil } }
        defer { lease.returned() }
        let cancelled: @Sendable () -> Bool = { lease.cancelled || isCancelled() }
        try check(cancelled)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typeflux-media-" + id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        lease.directory = directory
        try copy(input, to: directory.appendingPathComponent("input"), cancelled: cancelled)
        try check(cancelled)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw MediaFailure.unavailable }
        defer { close(fd) }
        let request = MediaRequest(id: id, operation: operation)
        do {
            let process = ManagedProcess.Request(executable: executable.path, environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                directoryDescriptor: fd, timeout: timeout, outputLimit: MediaLimits.responseBytes,
                stopOnOutputLimit: true, preserveWhitespace: true, onStarted: { lease.started() },
                stdin: try JSONEncoder().encode(request), stderrLimit: 1024,
                onReaped: { lease.reaped() })
            let result = try run(process, cancelled)
            try check(cancelled)
            guard result.termination == .exited(0), !result.outputTruncated,
                  result.stdout.utf8.count <= MediaLimits.responseBytes else { throw MediaFailure.unavailable }
            let response = try JSONDecoder().decode(MediaResponse.self, from: Data(result.stdout.utf8))
            try response.validate(for: request)
            try check(cancelled)
            return response
        } catch {
            // Bad media is a per-input refusal, not a reason to rebuild repeatedly.
            if !cancelled(), (error as? MediaFailure) != .unreadable, (error as? MediaFailure) != .tooLarge {
                lock.withLock { budget.failed(at: uptime()) }
            }
            throw error
        }
    }

    private func check(_ cancelled: () -> Bool) throws {
        if cancelled() { throw CancellationError() }
    }

    private func copy(_ input: Input, to target: URL, cancelled: () -> Bool) throws {
        switch input {
        case let .data(data):
            guard data.count <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
            try data.write(to: target, options: .withoutOverwriting)
        case let .file(url):
            // Reject FIFOs/devices without blocking open, and bound reads even if
            // the original file grows after its metadata was checked.
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw MediaFailure.unreadable }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MediaFailure.unreadable }
            guard info.st_size <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw MediaFailure.unavailable }
            defer { close(output) }
            var buffer = [UInt8](repeating: 0, count: 65536), total = 0
            while true {
                try check(cancelled)
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw MediaFailure.unreadable }
                total += count
                guard total <= MediaLimits.inputBytes else { throw MediaFailure.tooLarge }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        try check(cancelled)
                        let written = write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw MediaFailure.unavailable }
                        offset += written
                    }
                }
            }
        }
    }

    func preventNewWork() {
        let leases = lock.withLock { disabled = true; return Array(active.values) }
        leases.forEach { $0.cancel() }
    }

    func shutdown() async {
        preventNewWork()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while activeCount > 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    var activeCount: Int { lock.withLock { active.count } }
}

/// Cleanup needs both host completion and actual child collection. The pool
/// retains this lease when a child cannot be collected within the stop budget.
private final class MediaLease: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false, launched = false, collected = false, finished = false, cleaned = false
    var directory: URL?
    var cleanup: (@Sendable () -> Void)?
    var cancelled: Bool { lock.withLock { stopped } }
    func cancel() { lock.withLock { stopped = true } }
    func started() { lock.withLock { launched = true } }
    func reaped() { lock.withLock { collected = true }; collect(asynchronously: true) }
    func returned() { lock.withLock { finished = true }; collect(asynchronously: false) }
    private func collect(asynchronously: Bool) {
        let ready = lock.withLock {
            guard !cleaned, finished, !launched || collected else { return false }
            cleaned = true; return true
        }
        guard ready else { return }
        let remove: @Sendable () -> Void = { [self] in
            if let directory { try? FileManager.default.removeItem(at: directory) }
            cleanup?()
        }
        // A delayed reaper callback must not block collection of other children.
        if asynchronously { DispatchQueue.global(qos: .utility).async(execute: remove) }
        else { remove() }
    }
}
