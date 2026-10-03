import Darwin
import Foundation

/// Merged stdout/stderr is an ordered byte stream. Cursors count bytes, never
/// characters; the caller decodes UTF-8 across pages. Eviction is explicit.
struct AskTerminalOutput: Codable, Equatable {
    var data: Data
    var offset: Int64
    var nextCursor: Int64
    var lostBytes: Int64
}

struct AskProjectProcessStatus: Codable, Equatable {
    enum State: String, Codable {
        case starting, running, ready, exited, signalled, stopped, cancelled
        case timedOut, readinessTimedOut, revoked, appExit, invalidated
    }

    var state: State
    var pid: Int32
    var exitCode: Int32?
    var outputBytes: Int64 = 0
    var logTruncated = false
    var persistenceFailed = false
}

/// Thread-safe process ownership and I/O. The sandbox prohibits children, so
/// signalling the unreaped direct PID is sufficient even if it changes PGID.
final class AskTerminalSession: @unchecked Sendable {
    static let outputLimit = 1_048_576
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var status: AskProjectProcessStatus
    private var requestedStop: AskProjectProcessStatus.State?
    private var output = Data(), input = Data()
    private var endInput = false
    private var inputClosed = false
    private var canonicalLineBytes = 0
    private var outputClosed = false
    private let processIO: AskProjectProcessIO
    private let port: AskProjectPortLease?
    private let directory: AskSecureDirectory
    private let timeout: TimeInterval
    private let readinessTimeout: TimeInterval
    private var logBytes = 0
    private let logDescriptor: Int32

    init(request: AskProjectLaunchRequest, project: AskSecureDirectory, temporary: AskSecureDirectory,
         control: AskSecureDirectory, interpreter: String, port: AskProjectPortLease?) throws {
        self.port = port; directory = control
        timeout = request.timeout; readinessTimeout = request.readinessTimeout
        processIO = try AskProjectProcessIO(terminal: request.terminal)
        var cwd = project
        if request.cwd != "." {
            for part in try AskProjectFileAccess.parts(request.cwd) {
                cwd = try cwd.child(part)
            }
        }
        let projectPath = try project.url.path, tempPath = try temporary.url.path
        let profile = AskProjectRuntimePolicy.profile(project: projectPath, temporary: tempPath,
                                                      interpreter: interpreter, terminal: processIO.terminalPath,
                                                      port: port)
        let script = projectPath + "/" + request.script
        logDescriptor = openat(
            control.descriptor,
            "output.bin",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard logDescriptor >= 0 else { throw AskProjectError.denied }
        do {
            // -I excludes host/user-site injection. Add only the copied script's
            // directory for ordinary multi-file projects after loading runpy.
            let bootstrap = "import os,runpy,sys; sys.argv=sys.argv[1:]; " +
                "sys.path.insert(0,os.path.dirname(sys.argv[0])); runpy.run_path(sys.argv[0],run_name='__main__')"
            let pid = try AskProjectProcessIO.spawn(
                arguments: ["-p", profile, interpreter, "-I", "-u", "-B", "-c", bootstrap, script] + request.arguments,
                environment: AskProjectRuntimePolicy.environment(
                    request,
                    home: projectPath,
                    temporary: tempPath,
                    port: port
                ),
                cwd: cwd.descriptor, processIO: processIO, listener: port?.descriptor
            )
            status = .init(state: port == nil ? .running : .starting, pid: pid)
        } catch {
            close(logDescriptor)
            throw error
        }
        processIO.didSpawn()
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async { self.supervise(); self.finished.leave() }
    }

    deinit { close(logDescriptor) }

    func snapshot() -> AskProjectProcessStatus {
        lock.lock(); defer { lock.unlock() }; return status
    }

    func read(cursor: Int64, maximumBytes: Int = 65536) throws -> AskTerminalOutput {
        lock.lock(); defer { lock.unlock() }
        guard cursor >= 0, cursor <= status.outputBytes, (1 ... 65536).contains(maximumBytes) else {
            throw AskProjectRuntimeError.invalidCursor
        }
        let first = status.outputBytes - Int64(output.count), start = max(cursor, first)
        let index = Int(start - first), count = min(maximumBytes, output.count - index)
        return .init(data: output.subdata(in: index ..< index + count), offset: start,
                     nextCursor: start + Int64(count), lostBytes: start - cursor)
    }

    func send(_ data: Data, eof: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard [.starting, .running, .ready].contains(status.state), requestedStop == nil,
              !endInput, !inputClosed else { throw AskProjectRuntimeError.closed }
        guard data.count <= 65536 - input.count else { throw AskProjectRuntimeError.inputFull }
        if processIO.terminalPath != nil {
            // Stay below POSIX's minimum canonical line capacity across calls.
            // The terminal driver may silently drop an overlong line otherwise.
            var lineBytes = canonicalLineBytes
            for byte in data {
                lineBytes = [10, 13, 4].contains(byte) ? 0 : lineBytes + 1
                guard lineBytes <= 255 else { throw AskProjectRuntimeError.inputFull }
            }
            canonicalLineBytes = lineBytes
        }
        input.append(data); endInput = eof
    }

    func stop(_ reason: AskProjectProcessStatus.State = .stopped) {
        lock.lock()
        if requestedStop == nil {
            requestedStop = reason
        }
        lock.unlock()
        finished.wait()
    }

    private func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        status.outputBytes += Int64(data.count)
        output.append(data)
        if output.count > Self.outputLimit {
            // Rebase Data after eviction: removeFirst preserves a nonzero startIndex.
            output = Data(output.suffix(Self.outputLimit))
        }
        let remaining = max(0, Self.outputLimit - logBytes)
        if data.count > remaining {
            status.logTruncated = true
        }
        data.prefix(remaining).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(logDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { status.persistenceFailed = true; break }
                offset += count
            }
            logBytes += offset
        }
    }

    private func drain() {
        guard !outputClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0 ..< 8 {
            let count = Darwin.read(processIO.reader, &bytes, bytes.count)
            guard count > 0 else {
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    outputClosed = true
                }
                return
            }
            append(Data(bytes.prefix(count)))
        }
    }

    private func flushInput() {
        lock.lock(); defer { lock.unlock() }
        guard !inputClosed else { return }
        if !input.isEmpty {
            let count = input.withUnsafeBytes { write(processIO.writer, $0.baseAddress, $0.count) }
            if count > 0 {
                input.removeFirst(count)
            }
            if count < 0, errno != EAGAIN, errno != EINTR {
                inputClosed = true
            }
        }
        if input.isEmpty, endInput {
            if processIO.terminalPath != nil {
                // A first EOF may merely flush a partial canonical line. The
                // second produces an empty read even without a trailing newline.
                let eof: [UInt8] = [4, 4]
                if write(processIO.writer, eof, eof.count) != eof.count {
                    return
                }
            } else {
                processIO.closeInput()
            }
            inputClosed = true
        }
    }

    private func supervise() {
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .seconds(timeout))
        let readyDeadline = started.advanced(by: .seconds(readinessTimeout))
        var stopDeadline: ContinuousClock.Instant?
        var reason: AskProjectProcessStatus.State?
        var lastProbe = started.advanced(by: .seconds(-1))
        let pid = snapshot().pid
        var result: Int32 = 0
        while true {
            drain(); flushInput()
            let now = ContinuousClock.now
            if reason == nil {
                reason = cancellationReason(now: now, deadline: deadline, readyDeadline: readyDeadline)
            }
            if reason != nil, stopDeadline == nil {
                kill(pid, SIGTERM); stopDeadline = now.advanced(by: .milliseconds(150))
            }
            if let stopDeadline, now >= stopDeadline {
                kill(pid, SIGKILL)
            }
            // Reaping is the last PID operation. Never signal a numeric PID from
            // a persisted journal or after this waitpid has released ownership.
            let waited = waitpid(pid, &result, WNOHANG)
            if waited == pid {
                break
            }
            if waited < 0, errno != EINTR {
                reason = .invalidated; break
            }
            if reason == nil, snapshot().state == .starting, now - lastProbe >= .milliseconds(100) {
                lastProbe = now
                if port?.probe() == true {
                    lock.lock(); status.state = .ready; lock.unlock()
                }
            }
            // A closed output pipe must not turn POLLHUP into a busy loop while
            // the process continues running or waits for stdin.
            var item = pollfd(fd: outputClosed ? -1 : processIO.reader, events: Int16(POLLIN), revents: 0)
            poll(&item, 1, 5)
        }
        // No descendants can retain this writer. Drain the finite pipe/PTY tail.
        drain()
        processIO.closeAll(); port?.release()
        let signal = result & 0x7F
        lock.lock()
        status.exitCode = signal == 0 ? (result >> 8) & 0xFF : 128 + signal
        status.state = reason ?? (signal == 0 ? .exited : .signalled)
        lock.unlock()
        do {
            try directory.createFile("result.json", data: JSONEncoder().encode(snapshot()))
        } catch { lock.lock(); status.persistenceFailed = true; lock.unlock() }
    }

    private func cancellationReason(now: ContinuousClock.Instant, deadline: ContinuousClock.Instant,
                                    readyDeadline: ContinuousClock.Instant) -> AskProjectProcessStatus.State? {
        lock.lock(); defer { lock.unlock() }
        if let requestedStop {
            return requestedStop
        }
        if now >= deadline {
            return .timedOut
        }
        if status.state == .starting, now >= readyDeadline {
            return .readinessTimedOut
        }
        return nil
    }
}
