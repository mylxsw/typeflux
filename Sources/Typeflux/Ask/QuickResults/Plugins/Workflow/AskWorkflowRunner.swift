import Darwin
import Foundation

/// One process to start for a workflow run.
struct AskWorkflowInvocation: Sendable {
    var launch: AskWorkflowRuntime.Launch
    var environment: [String: String]
    var directory: URL
    var stdin: Data
    var timeout: Double
    var stdoutLimit = 1_000_000
    var stderrLimit = 256_000
}

/// How a run ended.
struct AskWorkflowRunResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var duration: Double
    var timedOut = false
    /// The output passed its limit and the run was stopped.
    var truncated = false
}

enum AskWorkflowRunEvent: Equatable, Sendable {
    /// Everything printed so far, up to the last complete line.
    case output(String)
    case finished(AskWorkflowRunResult)
}

enum AskWorkflowRunError: Error, Equatable {
    /// The process could not start; carries `errno`.
    case spawnFailed(Int32)
}

/// Runs workflow processes. Each run gets its own process group, so a timeout or
/// a cancel ends everything the script started; its environment is exactly the
/// one given, never Typeflux's own; and its output is capped.
protocol AskWorkflowRunning: Sendable {
    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error>
}

final class AskWorkflowRunner: AskWorkflowRunning, @unchecked Sendable {
    /// How long a process gets to exit after SIGTERM before SIGKILL.
    var killGrace: Double = 1
    /// How long output may keep arriving after the process exits.
    var drainGrace: Double = 0.3

    func run(_ invocation: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error> {
        AsyncThrowingStream { continuation in
            let run = Run(invocation: invocation, continuation: continuation, killGrace: killGrace, drainGrace: drainGrace)
            continuation.onTermination = { reason in
                if case .cancelled = reason { run.cancel() }
            }
            run.start()
        }
    }

    /// One running process, watched by a thread of its own: a `poll` loop over its
    /// output, its input and a wake-up pipe. Nothing waits on a shared thread pool,
    /// so a busy app (or a busy test run) cannot stall a workflow.
    private final class Run: @unchecked Sendable {
        private let invocation: AskWorkflowInvocation
        private let continuation: AsyncThrowingStream<AskWorkflowRunEvent, Error>.Continuation
        private let killGrace: Double
        private let drainGrace: Double
        private let lock = NSLock()
        private var cancelled = false
        /// Written to by `cancel()` to wake the loop.
        private var wake: [Int32] = [-1, -1]

        init(invocation: AskWorkflowInvocation, continuation: AsyncThrowingStream<AskWorkflowRunEvent, Error>.Continuation,
             killGrace: Double, drainGrace: Double) {
            self.invocation = invocation
            self.continuation = continuation
            self.killGrace = killGrace
            self.drainGrace = drainGrace
        }

        func start() {
            var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1], errors: [Int32] = [-1, -1]
            guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0, pipe(&wake) == 0 else {
                let code = errno
                (input + output + errors + wake).filter { $0 >= 0 }.forEach { close($0) }
                continuation.finish(throwing: AskWorkflowRunError.spawnFailed(code))
                return
            }
            let spawned = spawn(stdin: input[0], stdout: output[1], stderr: errors[1])
            close(input[0]); close(output[1]); close(errors[1])
            guard case let .success(child) = spawned else {
                close(input[1]); close(output[0]); close(errors[0]); close(wake[0]); close(wake[1])
                if case let .failure(error) = spawned { continuation.finish(throwing: error) }
                return
            }
            let thread = Thread { [self] in
                watch(child, stdin: input[1], stdout: output[0], stderr: errors[0])
            }
            thread.name = "typeflux.workflow.run"
            thread.start()
        }

        private func spawn(stdin: Int32, stdout: Int32, stderr: Int32) -> Result<pid_t, AskWorkflowRunError> {
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
            posix_spawn_file_actions_adddup2(&actions, stdout, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
            posix_spawn_file_actions_addchdir_np(&actions, invocation.directory.path)
            // A new process group, no inherited descriptors, default signal handling.
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
            posix_spawnattr_setpgroup(&attributes, 0)
            var all = sigset_t(), none = sigset_t()
            sigfillset(&all); sigemptyset(&none)
            posix_spawnattr_setsigdefault(&attributes, &all)
            posix_spawnattr_setsigmask(&attributes, &none)

            let path = invocation.launch.executable.path
            let argv = ([path] + invocation.launch.arguments).map { strdup($0) } + [nil]
            let envp = invocation.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var child: pid_t = 0
            let status = posix_spawn(&child, path, &actions, &attributes, argv, envp)
            return status == 0 ? .success(child) : .failure(.spawnFailed(status))
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let descriptor = wake[1]
            lock.unlock()
            if descriptor >= 0 { var byte: UInt8 = 1; _ = Darwin.write(descriptor, &byte, 1) }
        }

        private var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        // swiftlint:disable:next function_body_length cyclomatic_complexity
        private func watch(_ child: pid_t, stdin: Int32, stdout: Int32, stderr: Int32) {
            let started = Date()
            let deadline = started.addingTimeInterval(invocation.timeout)
            // A script that exits without reading stdin must not take Typeflux down with SIGPIPE.
            _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
            for descriptor in [stdin, stdout, stderr, wake[0]] {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            }
            var input = stdin, output = stdout, errors = stderr
            var pending = invocation.stdin
            if pending.isEmpty { close(input); input = -1 }
            var out = Data(), err = Data(), emitted = 0
            var timedOut = false, truncated = false
            var terminatedAt: Date?, exitedAt: Date?, exitCode: Int32 = 0
            var buffer = [UInt8](repeating: 0, count: 65536)

            func terminate() {
                guard terminatedAt == nil, exitedAt == nil else { return }
                terminatedAt = Date()
                kill(-child, SIGTERM)
            }

            func drain(_ descriptor: inout Int32, isStdout: Bool) {
                while descriptor >= 0 {
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        let limit = isStdout ? invocation.stdoutLimit : invocation.stderrLimit
                        let current = isStdout ? out.count : err.count
                        let room = max(0, limit - current)
                        let chunk = Data(buffer[0 ..< min(count, room)])
                        if isStdout { out.append(chunk) } else { err.append(chunk) }
                        if count > room, !truncated { truncated = true; terminate() }
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        close(descriptor); descriptor = -1
                    } else {
                        return
                    }
                }
            }

            while true {
                // The process: exited, or due a signal.
                if exitedAt == nil {
                    var status: Int32 = 0
                    let reaped = waitpid(child, &status, WNOHANG)
                    if reaped == child || (reaped == -1 && errno == ECHILD) {
                        exitedAt = Date()
                        exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
                        // Anything the script left running in its group goes with it.
                        kill(-child, SIGKILL)
                    }
                }
                let now = Date()
                if exitedAt == nil {
                    if isCancelled { terminate() }
                    if now >= deadline, !timedOut { timedOut = true; terminate() }
                    if let terminatedAt, now.timeIntervalSince(terminatedAt) >= killGrace { kill(-child, SIGKILL) }
                }
                // Output a detached grandchild still holds open is not waited for.
                if let exitedAt, (output < 0 && errors < 0) || now.timeIntervalSince(exitedAt) >= drainGrace { break }

                var fds: [pollfd] = []
                if output >= 0 { fds.append(pollfd(fd: output, events: Int16(POLLIN), revents: 0)) }
                if errors >= 0 { fds.append(pollfd(fd: errors, events: Int16(POLLIN), revents: 0)) }
                if input >= 0 { fds.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0)) }
                fds.append(pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0))
                // Wake at least every 50 ms to check on the process and the clock.
                _ = poll(&fds, nfds_t(fds.count), 50)
                for item in fds where item.revents != 0 {
                    switch item.fd {
                    case output:
                        drain(&output, isStdout: true)
                    case errors:
                        drain(&errors, isStdout: false)
                    case wake[0]:
                        var byte: UInt8 = 0
                        while Darwin.read(wake[0], &byte, 1) > 0 {}
                    default:
                        let written = pending.withUnsafeBytes { Darwin.write(input, $0.baseAddress!, $0.count) }
                        if written > 0 { pending.removeFirst(written) }
                        if pending.isEmpty || (written < 0 && errno != EAGAIN && errno != EINTR) { close(input); input = -1 }
                    }
                }
                if let end = out.lastIndex(of: 0x0A), end + 1 > emitted {
                    emitted = end + 1
                    continuation.yield(.output(String(decoding: out.prefix(end + 1), as: UTF8.self)))
                }
            }
            [input, output, errors, wake[0]].filter { $0 >= 0 }.forEach { close($0) }
            lock.lock()
            close(wake[1]); wake[1] = -1
            lock.unlock()
            continuation.yield(.finished(AskWorkflowRunResult(
                exitCode: exitCode,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                duration: Date().timeIntervalSince(started),
                timedOut: timedOut,
                truncated: truncated
            )))
            continuation.finish()
        }
    }
}
