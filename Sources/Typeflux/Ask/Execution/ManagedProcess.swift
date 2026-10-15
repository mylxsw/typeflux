import Darwin
import Foundation

/// Owns one POSIX process group, not an arbitrary hostile process tree. Callers
/// must prevent group/session escape separately before running untrusted code.
/// Keeps spawning, PID ownership and the bounded I/O lifecycle together.
struct ManagedProcess: Sendable { // swiftlint:disable:this type_body_length
    struct Request: Sendable {
        var executable: String
        var arguments: [String] = []
        var environment: [String: String]
        /// Kept open by the caller until run returns; never inherited by the child.
        var directoryDescriptor: Int32
        var timeout: TimeInterval
        var outputLimit: Int = 30000
        var stopOnOutputLimit = false
        var preserveWhitespace = false
        var onStarted: (@Sendable () -> Void)?
        var stdin: Data?
        var stderrLimit: Int?
        var killGrace: TimeInterval = 0.2
        var drainGrace: TimeInterval = 0.3
        /// Cumulative, bounded stdout through its last complete line.
        var onOutput: (@Sendable (String) -> Void)?
        var immediateCleanupOnExit = false
    }

    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case cancelled
        case outputLimit
    }

    struct Result: Sendable {
        var termination: Termination
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var outputTruncated: Bool
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        private let external: @Sendable () -> Bool

        init(external: @escaping @Sendable () -> Bool = { false }) {
            self.external = external
        }

        func cancel() {
            lock.lock(); value = true; lock.unlock()
        }

        var isCancelled: Bool {
            let cancelled = lock.withLock { value }
            return cancelled || external()
        }
    }

    func run(_ request: Request) async throws -> Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result { try Self.execute(request, cancellation: cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// For an owned serial worker queue only, never the main thread. Cancellation
    /// remains cooperative at the host boundary and forcibly stops the child.
    func runBlocking(_ request: Request, isCancelled: @escaping @Sendable () -> Bool) throws -> Result {
        try Self.execute(request, cancellation: Cancellation(external: isCancelled))
    }

    private static func validate(_ request: Request) throws {
        let strings = [request.executable] + request.arguments + request.environment.map { "\($0.key)=\($0.value)" }
        guard request.timeout.isFinite, request.timeout > 0, request.outputLimit >= 0,
              request.timeout <= 86400, request.outputLimit <= 32 * 1024 * 1024, request.executable.hasPrefix("/"),
              (request.stderrLimit ?? request.outputLimit) >= 0,
              (request.stderrLimit ?? request.outputLimit) <= 32 * 1024 * 1024,
              (request.stdin?.count ?? 0) <= 32 * 1024 * 1024,
              request.killGrace.isFinite, (0 ... 5).contains(request.killGrace),
              request.drainGrace.isFinite, (0 ... 5).contains(request.drainGrace),
              strings.allSatisfy({ !$0.contains("\0") }),
              request.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
    }

    // The single lifecycle loop owns every exit and cleanup path.
    // swiftlint:disable:next function_body_length
    private static func execute(_ request: Request, cancellation: Cancellation) throws -> Result {
        try validate(request)
        // This single monotonic deadline includes spawn and both pipe drains.
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeout))
        if cancellation.isCancelled {
            throw CancellationError()
        }
        try OwnedProcessReaper.shared.reserve()
        var child: pid_t?
        defer {
            if let child {
                OwnedProcessReaper.shared.collect(child)
            } else {
                OwnedProcessReaper.shared.release()
            }
        }
        let out = try OutputPipe(limit: request.outputLimit)
        let err = try OutputPipe(limit: request.stderrLimit ?? request.outputLimit)
        let input = try request.stdin.map { try InputPipe(data: $0) }
        let pid = try spawn(request, stdin: input?.reader, stdout: out.writer, stderr: err.writer)
        child = pid
        request.onStarted?()
        input?.closeReader()
        out.closeWriter()
        err.closeWriter()
        var lifecycle = Lifecycle(pid: pid, deadline: deadline, killGrace: request.killGrace,
                                  drainGrace: request.drainGrace,
                                  immediateCleanupOnExit: request.immediateCleanupOnExit)
        var emitted = 0
        while true {
            do {
                try lifecycle.update(cancelled: cancellation.isCancelled)
            } catch {
                // Ownership is no longer provable. Do not signal a reused PID.
                child = nil
                throw error
            }
            input?.writeAvailable()
            out.drain()
            err.drain()
            if let onOutput = request.onOutput, let prefix = out.output.completeLines(after: emitted) {
                emitted = prefix.count
                // Preserve arbitrary process bytes, including split UTF-8 sequences.
                // swiftlint:disable:next optional_data_string_conversion
                onOutput(String(decoding: prefix, as: UTF8.self))
            }
            if request.stopOnOutputLimit, lifecycle.reason == nil,
               out.output.isTruncated || err.output.isTruncated {
                lifecycle.reason = .outputLimit
            }
            if lifecycle.finished(pipesClosed: out.reader < 0 && err.reader < 0) {
                break
            }
            var descriptors = [pollfd(fd: out.reader, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: err.reader, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: input?.writer ?? -1, events: Int16(POLLOUT), revents: 0)]
            poll(&descriptors, nfds_t(descriptors.count), 5)
        }
        // WNOWAIT retained PID ownership through the final group signal. A stuck
        // child stays in the bounded reaper instead of blocking this continuation.
        let termination = lifecycle.reason ?? lifecycle.parentTermination ?? .timedOut
        let exitCode: Int32 = switch lifecycle.parentTermination {
        case let .exited(code): code
        case let .signalled(signal): 128 + signal
        default: 128 + SIGKILL
        }
        return Result(termination: termination,
                      exitCode: exitCode,
                      stdout: request.preserveWhitespace ? out.output.rawText : out.output.text,
                      stderr: request.preserveWhitespace ? err.output.rawText : err.output.text,
                      outputTruncated: out.output.isTruncated || err.output.isTruncated)
    }

    private struct Lifecycle {
        let pid: pid_t
        let deadline: ContinuousClock.Instant
        let killGrace: TimeInterval
        let drainGrace: TimeInterval
        let immediateCleanupOnExit: Bool
        var reason: Termination?
        var cleanupDeadline: ContinuousClock.Instant?
        var parentTermination: Termination?
        var sentKill = false

        mutating func update(cancelled: Bool) throws {
            let now = ContinuousClock.now
            // First observed reason is stable. Cancellation wins a simultaneous expiry.
            if reason == nil {
                if cancelled {
                    reason = .cancelled
                } else if now >= deadline {
                    reason = .timedOut
                }
            }
            var info = siginfo_t()
            let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            // A competing reaper invalidates PID ownership. Never signal a PID
            // that may already have been reused; report the violated contract.
            if observed != 0, errno != EINTR {
                throw AskSecureDirectory.failure("observe owned child")
            }
            if observed == 0, info.si_pid == pid {
                parentTermination = info.si_code == CLD_EXITED ? .exited(info.si_status) : .signalled(info.si_status)
            }
            if immediateCleanupOnExit, parentTermination != nil, cleanupDeadline == nil {
                // The leader has finished. Retain its PID while killing leftovers,
                // but do not add the cancellation grace to every short command.
                signal(SIGKILL)
                sentKill = true
                cleanupDeadline = now
            }
            if cleanupDeadline == nil, reason != nil || parentTermination != nil {
                // Reserve the leader's PID until the last group signal; otherwise
                // PID/PGID reuse could target an unrelated process.
                signal(SIGTERM)
                cleanupDeadline = now.advanced(by: .seconds(killGrace))
            }
            if let cleanupDeadline, now >= cleanupDeadline, !sentKill {
                signal(SIGKILL)
                sentKill = true
            }
        }

        mutating func finished(pipesClosed: Bool) -> Bool {
            if parentTermination != nil, pipesClosed {
                if reason == nil {
                    reason = parentTermination
                }
                if sentKill {
                    return true
                }
            }
            // An escaped descendant can retain a writer forever. Bounded closure
            // of our readers is not proof that escaped descendants were killed.
            return cleanupDeadline.map { ContinuousClock.now >= $0.advanced(by: .seconds(drainGrace)) } ?? false
        }

        func signal(_ value: Int32) {
            kill(-pid, value)
            kill(pid, value)
        }
    }

    private final class OutputPipe {
        private(set) var reader: Int32 = -1
        private(set) var writer: Int32 = -1
        let output: AskOutputCollector
        private var buffer = [UInt8](repeating: 0, count: 8192)

        init(limit: Int) throws {
            output = AskOutputCollector(limit: limit)
            var pair = [Int32](repeating: -1, count: 2)
            guard pipe(&pair) == 0 else { throw AskSecureDirectory.failure("pipe") }
            reader = pair[0]
            writer = pair[1]
            guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(reader, F_SETFL, O_NONBLOCK) == 0 else {
                throw AskSecureDirectory.failure("configure pipe")
            }
        }

        deinit {
            if reader >= 0 {
                close(reader)
            }
            if writer >= 0 {
                close(writer)
            }
        }

        func closeWriter() {
            close(writer); writer = -1
        }

        func drain() {
            guard reader >= 0 else { return }
            // A flood cannot starve the second stream or lifecycle checks.
            for _ in 0 ..< 8 {
                let count = read(reader, &buffer, buffer.count)
                if count > 0 {
                    output.append(Data(buffer.prefix(count)))
                } else {
                    if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        close(reader)
                        reader = -1
                    }
                    return
                }
            }
        }
    }

    private static func spawn(_ request: Request, stdin: Int32?, stdout: Int32, stderr: Int32) throws -> pid_t {
        func check(_ code: Int32) throws {
            if code != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            try check(posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO))
        } else {
            try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        }
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))
        if #available(macOS 26.0, *) {
            try check(posix_spawn_file_actions_addfchdir(&actions, request.directoryDescriptor))
        } else {
            try check(posix_spawn_file_actions_addfchdir_np(&actions, request.directoryDescriptor))
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty)
        sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &empty))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        ))
        let arguments = ([request.executable] + request.arguments).map { strdup($0) } + [nil]
        let environment = request.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        var pid: pid_t = 0
        try arguments.withUnsafeBufferPointer { argv in
            try environment.withUnsafeBufferPointer { envp in
                try check(posix_spawn(&pid, request.executable, &actions, &attributes,
                                      UnsafeMutablePointer(mutating: argv.baseAddress!),
                                      UnsafeMutablePointer(mutating: envp.baseAddress!)))
            }
        }
        return pid
    }
}

/// Byte-bounded collection while continuing to drain discarded output.
final class AskOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var dropped = 0
    private var lastCompleteLineEnd = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, limit - data.count)
        let retained = chunk.prefix(room)
        if let end = retained.lastIndex(of: 10) {
            lastCompleteLineEnd = data.count + retained.distance(from: retained.startIndex, to: end) + 1
        }
        data.append(retained)
        let (sum, overflow) = dropped.addingReportingOverflow(max(0, chunk.count - room))
        dropped = overflow ? Int.max : sum
    }

    var isTruncated: Bool {
        lock.lock(); defer { lock.unlock() }; return dropped > 0
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        // Lossy decoding preserves arbitrary subprocess bytes, including split UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return dropped > 0 ? body + "\n[\(dropped) more bytes omitted]" : body
    }

    var rawText: String {
        lock.lock(); defer { lock.unlock() }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }

    func completeLines(after offset: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard lastCompleteLineEnd > offset else { return nil }
        return data.prefix(lastCompleteLineEnd)
    }
}

private final class InputPipe {
    private(set) var reader: Int32 = -1
    private(set) var writer: Int32 = -1
    private let data: Data
    private var offset = 0

    init(data: Data) throws {
        self.data = data
        var pair: [Int32] = [-1, -1]
        guard pipe(&pair) == 0 else { throw AskSecureDirectory.failure("input pipe") }
        reader = pair[0]; writer = pair[1]
        guard fcntl(reader, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(writer, F_SETFL, O_NONBLOCK) == 0,
              fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else { throw AskSecureDirectory.failure("configure input pipe") }
    }

    deinit {
        if reader >= 0 {
            close(reader)
        }
        if writer >= 0 {
            close(writer)
        }
    }

    func closeReader() {
        close(reader); reader = -1
    }

    func writeAvailable() {
        guard writer >= 0 else { return }
        if offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(writer, $0.baseAddress!.advanced(by: offset), min(65536, data.count - offset))
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno != EAGAIN, errno != EINTR {
                close(writer); writer = -1; return
            }
        }
        if offset == data.count {
            close(writer); writer = -1
        }
    }
}
