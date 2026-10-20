import Darwin
import Foundation

struct TerminalSize: Equatable, Sendable {
    var columns: Int
    var rows: Int

    static let standard = TerminalSize(columns: 80, rows: 24)
}

enum TerminalProcessError: Error, LocalizedError, Equatable {
    case directoryMissing(String)
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .directoryMissing(path): L("terminal.runner.error.directory", path)
        case let .spawnFailed(code): L("terminal.runner.error.spawn", String(cString: strerror(code)))
        }
    }
}

/// One command running in a pseudo-terminal. Callbacks arrive on the main queue: all
/// output first, then exactly one exit.
protocol TerminalProcess: AnyObject {
    var onOutput: (([UInt8]) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    func start(_ launch: TerminalShellLaunch, size: TerminalSize) throws
    func write(_ bytes: [UInt8])
    func resize(_ size: TerminalSize)
    /// True while the command reads input with echo turned off, as for a password.
    var readsHiddenInput: Bool { get }
    /// Hangs up the command and everything it started, escalating to SIGTERM and SIGKILL.
    func terminate()
}

/// A `forkpty` session. The child becomes a session leader with the terminal as its
/// controlling terminal, so job control, Ctrl-C and SIGWINCH behave as in a terminal app.
final class TerminalPTYProcess: TerminalProcess, @unchecked Sendable {
    var onOutput: (([UInt8]) -> Void)?
    var onExit: ((Int32) -> Void)?

    /// Output not yet consumed on the main queue. Reading pauses above this, so a
    /// command printing without pause cannot grow memory without bound.
    static let backlogLimit = 1 << 20
    /// After the exit, output still buffered in the terminal is read for this long.
    static let drainGrace: DispatchTimeInterval = .milliseconds(250)
    static let escalationDelay: DispatchTimeInterval = .seconds(2)
    static let writeLimit = 1 << 20

    private let queue = DispatchQueue(label: "ai.typeflux.terminal-pty", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    // Owned by `queue`.
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var exitSource: DispatchSourceProcess?
    private var pendingWrite: [UInt8] = []
    private var backlog = 0
    private var readPaused = false
    private var outputClosed = false
    private var exitStatus: Int32?
    private var reported = false
    private var terminating = false
    private var foregroundGroup: pid_t = 0

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    deinit {
        // A window closed without `terminate()` must not leave the command or descriptor behind.
        let master = master, pid = pid, exited = exitStatus != nil
        // Releasing a suspended source is a crash; resume it so it can be cancelled.
        if readPaused { readSource?.resume() }
        readSource?.cancel(); writeSource?.cancel(); exitSource?.cancel()
        if pid > 0, !exited { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
        if master >= 0, readSource == nil { close(master) }
    }

    func start(_ launch: TerminalShellLaunch, size: TerminalSize) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.directory, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw TerminalProcessError.directoryMissing(launch.directory) }
        let (pid, master) = try Self.spawn(launch, size: size)
        queue.sync {
            self.pid = pid
            self.master = master
            _ = fcntl(master, F_SETFD, FD_CLOEXEC)
            _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
            // Erasing a multibyte character in line input removes the whole character.
            var attributes = termios()
            if tcgetattr(master, &attributes) == 0 {
                attributes.c_iflag |= tcflag_t(IUTF8)
                _ = tcsetattr(master, TCSANOW, &attributes)
            }
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [weak self] in self?.reap() }
            exitSource = exit
            exit.activate()
            let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            read.setEventHandler { [weak self] in self?.readAvailable() }
            read.setCancelHandler { close(master) }
            readSource = read
            read.activate()
            // An exit before the source was armed delivers no event.
            reap()
        }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [self] in
            guard master >= 0, !outputClosed, exitStatus == nil else { return }
            // A paste larger than the limit is cut rather than buffered without bound.
            pendingWrite += bytes.prefix(max(0, Self.writeLimit - pendingWrite.count))
            flushWrites()
        }
    }

    func resize(_ size: TerminalSize) {
        queue.async { [self] in
            guard master >= 0, !outputClosed else { return }
            var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
                                 ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &window)
        }
    }

    var readsHiddenInput: Bool {
        queue.sync {
            guard master >= 0, !outputClosed, exitStatus == nil else { return false }
            var attributes = termios()
            guard tcgetattr(master, &attributes) == 0 else { return false }
            return attributes.c_lflag & tcflag_t(ECHO) == 0 && attributes.c_lflag & tcflag_t(ICANON) != 0
        }
    }

    func terminate() {
        queue.async { [self] in
            guard pid > 0, exitStatus == nil, !terminating else { return }
            terminating = true
            if master >= 0, !outputClosed {
                let group = tcgetpgrp(master)
                if group > 0, group != pid { foregroundGroup = group }
            }
            signalAll(SIGHUP)
            // Strong captures: the window may already be gone, but the command must still
            // be ended and reaped rather than left running or as a zombie.
            queue.asyncAfter(deadline: .now() + Self.escalationDelay) { [self] in
                guard exitStatus == nil else { return }
                signalAll(SIGTERM)
                queue.asyncAfter(deadline: .now() + Self.escalationDelay) { [self] in
                    guard exitStatus == nil else { return }
                    signalAll(SIGKILL)
                    queue.asyncAfter(deadline: .now() + Self.drainGrace) { [self] in reap() }
                }
            }
        }
    }

    /// Lets the main queue report how much output it has taken in.
    private func consumed(_ count: Int) {
        queue.async { [self] in
            backlog -= count
            if readPaused, backlog < Self.backlogLimit / 2, let readSource {
                readPaused = false
                readSource.resume()
            }
        }
    }

    // MARK: - Queue-owned work

    private func signalAll(_ signal: Int32) {
        // Only while the leader is unreaped, so the group ID cannot belong to another process.
        guard pid > 0, exitStatus == nil else { return }
        if foregroundGroup > 0 { kill(-foregroundGroup, signal) }
        kill(-pid, signal)
        kill(pid, signal)
    }

    private func readAvailable() {
        guard !outputClosed, master >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while backlog < Self.backlogLimit {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                deliver(Array(buffer[0 ..< count]))
                continue
            }
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            // EOF, or EIO once no process holds the terminal any more.
            closeOutput()
            return
        }
        if !readPaused, let readSource {
            readPaused = true
            readSource.suspend()
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        backlog += bytes.count
        let count = bytes.count
        callbackQueue.async { [weak self] in
            self?.onOutput?(bytes)
            self?.consumed(count)
        }
    }

    private func flushWrites() {
        while !pendingWrite.isEmpty {
            let count = pendingWrite.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if count > 0 {
                pendingWrite.removeFirst(count)
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
                    source.setEventHandler { [weak self] in self?.flushWrites() }
                    writeSource = source
                    source.activate()
                }
                return
            }
            pendingWrite.removeAll()
            break
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func reap() {
        guard pid > 0, exitStatus == nil else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid || (result < 0 && errno == ECHILD) else { return }
        exitStatus = result == pid ? Self.exitCode(fromWaitStatus: status) : 128
        exitSource?.cancel()
        exitSource = nil
        if outputClosed {
            report()
        } else {
            readAvailable()
            scheduleDrain()
        }
    }

    /// A background process may keep the terminal open after the command exits; its output
    /// is no longer waited for once the buffered output is read.
    private func scheduleDrain() {
        queue.asyncAfter(deadline: .now() + Self.drainGrace) { [weak self] in
            guard let self, !self.outputClosed else { return }
            // Paused while the window catches up: the output is still the command's own.
            if self.readPaused { self.scheduleDrain(); return }
            self.readAvailable()
            self.closeOutput()
        }
    }

    private func closeOutput() {
        guard !outputClosed else { return }
        outputClosed = true
        pendingWrite.removeAll()
        writeSource?.cancel()
        writeSource = nil
        if let readSource {
            // A suspended source must be resumed before it can be cancelled.
            if readPaused { readPaused = false; readSource.resume() }
            // The cancel handler closes the terminal, hanging up anything still attached.
            readSource.cancel()
        }
        if exitStatus != nil { report() }
    }

    private func report() {
        guard !reported, let exitStatus else { return }
        reported = true
        callbackQueue.async { [weak self] in self?.onExit?(exitStatus) }
    }

    /// `WEXITSTATUS`, or 128 plus the signal for a command that was killed, as shells report it.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    // MARK: - Spawning

    /// Everything the child touches is prepared before `forkpty`; between fork and exec the
    /// child only calls async-signal-safe functions.
    private static func spawn(_ launch: TerminalShellLaunch, size: TerminalSize) throws -> (pid_t, Int32) {
        let arguments = CStringList(launch.arguments)
        let environment = CStringList(launch.environmentList)
        let executable = strdup(launch.executable)
        let directory = strdup(launch.directory)
        defer { free(executable); free(directory) }
        var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns),
                             ws_xpixel: 0, ws_ypixel: 0)
        let descriptorLimit = min(Int32(getdtablesize()), 65536)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &window)
        if pid < 0 { throw TerminalProcessError.spawnFailed(errno) }
        if pid == 0 {
            // The app ignores or blocks some signals; the command expects the defaults.
            // Plain calls only: nothing here may allocate.
            Darwin.signal(SIGPIPE, SIG_DFL); Darwin.signal(SIGINT, SIG_DFL); Darwin.signal(SIGQUIT, SIG_DFL)
            Darwin.signal(SIGTERM, SIG_DFL); Darwin.signal(SIGHUP, SIG_DFL); Darwin.signal(SIGCHLD, SIG_DFL)
            Darwin.signal(SIGTSTP, SIG_DFL); Darwin.signal(SIGTTIN, SIG_DFL); Darwin.signal(SIGTTOU, SIG_DFL)
            Darwin.signal(SIGWINCH, SIG_DFL)
            sigprocmask(SIG_SETMASK, &emptyMask, nil)
            // The app's own files and sockets must not reach the command.
            var descriptor: Int32 = 3
            while descriptor < descriptorLimit {
                close(descriptor)
                descriptor += 1
            }
            if chdir(directory) != 0 { _exit(126) }
            execve(executable, arguments.pointers, environment.pointers)
            _exit(127)
        }
        return (pid, master)
    }
}

/// A NULL-terminated C string array that lives until it is deinitialized.
private final class CStringList {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[count] = nil
    }

    deinit {
        for index in 0 ..< count {
            free(pointers[index])
        }
        pointers.deallocate()
    }
}
