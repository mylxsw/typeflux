import Darwin
import Foundation

/// Owns one POSIX process group, not an arbitrary hostile process tree. Callers
/// must prevent group/session escape separately before running untrusted code.
struct ManagedProcess: Sendable {
    struct Request: Sendable {
        var executable: String
        var arguments: [String] = []
        var environment: [String: String]
        /// Kept open by the caller until run returns; never inherited by the child.
        var directoryDescriptor: Int32
        var timeout: TimeInterval
        var outputLimit: Int = 30000
    }

    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case cancelled
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
        func cancel() {
            lock.lock(); value = true; lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return value
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

    private static func validate(_ request: Request) throws {
        let strings = [request.executable] + request.arguments + request.environment.map { "\($0.key)=\($0.value)" }
        guard request.timeout.isFinite, request.timeout > 0, request.outputLimit >= 0,
              request.outputLimit <= 1_000_000, request.executable.hasPrefix("/"),
              strings.allSatisfy({ !$0.contains("\0") }),
              request.environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
    }

    private static func execute(_ request: Request, cancellation: Cancellation) throws -> Result {
        try validate(request)
        // This single monotonic deadline includes spawn and both pipe drains.
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeout))
        if cancellation.isCancelled {
            throw CancellationError()
        }
        let out = try OutputPipe(limit: request.outputLimit), err = try OutputPipe(limit: request.outputLimit)
        let pid = try spawn(request, stdout: out.writer, stderr: err.writer)
        out.closeWriter()
        err.closeWriter()
        var lifecycle = Lifecycle(pid: pid, deadline: deadline)
        while true {
            try lifecycle.update(cancelled: cancellation.isCancelled)
            out.drain()
            err.drain()
            if lifecycle.finished(pipesClosed: out.reader < 0 && err.reader < 0) {
                break
            }
            var descriptors = [pollfd(fd: out.reader, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: err.reader, events: Int16(POLLIN), revents: 0)]
            poll(&descriptors, 2, 5)
        }
        // Only reap our direct child. No wait for pipe EOF occurs outside the
        // deadline. A kernel-uninterruptible process is outside the latency SLO.
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR {
                throw AskSecureDirectory.failure("reap process")
            }
        }
        let signal = status & 0x7F
        let exitCode = signal == 0 ? (status >> 8) & 0xFF : 128 + signal
        return Result(termination: lifecycle.reason ?? (signal == 0 ? .exited(exitCode) : .signalled(signal)),
                      exitCode: exitCode, stdout: out.output.text, stderr: err.output.text,
                      outputTruncated: out.output.isTruncated || err.output.isTruncated)
    }

    private struct Lifecycle {
        let pid: pid_t
        let deadline: ContinuousClock.Instant
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
            if cleanupDeadline == nil, reason != nil || parentTermination != nil {
                // Reserve the leader's PID until the last group signal; otherwise
                // PID/PGID reuse could target an unrelated process.
                signal(SIGTERM)
                cleanupDeadline = now.advanced(by: .milliseconds(200))
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
            return cleanupDeadline.map { ContinuousClock.now >= $0.advanced(by: .milliseconds(300)) } ?? false
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

    private static func spawn(_ request: Request, stdout: Int32, stderr: Int32) throws -> pid_t {
        func check(_ code: Int32) throws {
            if code != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
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
    private let limit: Int

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, limit - data.count)
        data.append(chunk.prefix(room))
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
}
