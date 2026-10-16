import Darwin
import Foundation

/// One serial reader lineage. Replacements retain the same admission until both
/// the old child and its synchronous host callback have retired.
final class AskFileReaderOwnership: @unchecked Sendable {
    private let condition = NSLock()
    private var current: UUID?
    private var hosts = 0
    private var collected = false

    func reserve(isCancelled: () -> Bool) throws -> UUID {
        condition.lock(); defer { condition.unlock() }
        // A short collection grace preserves healthy siblings after a killed
        // directory read. This never waits for an uninterruptible child forever.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while current != nil {
            if isCancelled() { throw AskFileReadError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AskFileReadError.unavailable }
            condition.unlock(); usleep(10_000); condition.lock()
        }
        if isCancelled() { throw AskFileReadError.cancelled }
        let id = UUID(); current = id; hosts = 0; collected = false; return id
    }
    func begin(_ id: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        guard current == id, !collected else { throw AskFileReadError.unavailable }
        hosts += 1
    }
    func end(_ id: UUID) { update(id, host: true) }
    func reaped(_ id: UUID) { update(id, host: false) }
    private func update(_ id: UUID, host: Bool) {
        condition.lock(); defer { condition.unlock() }
        guard current == id else { return }
        if host { hosts -= 1 } else { collected = true }
        if collected && hosts == 0 { current = nil }
    }
    var isOccupied: Bool {
        condition.lock(); defer { condition.unlock() }; return current != nil
    }
}

/// POSIX ownership keeps the PID reserved until the last signal. Foundation's
/// asynchronous Process reaper must not race a later raw kill(pid).
final class AskFileReaderProcess {
    let id: UUID
    let pid: pid_t
    private let ownership: AskFileReaderOwnership
    private let reaper: OwnedProcessReaper
    private var stopped = false

    init(executable: URL, arguments: [String], input: Int32, output: Int32,
         qualityOfService: QualityOfService?, ownership: AskFileReaderOwnership,
         reaper: OwnedProcessReaper, isCancelled: () -> Bool) throws {
        let id = try ownership.reserve(isCancelled: isCancelled)
        do {
            try reaper.reserve()
            do { pid = try Self.spawn(executable, arguments, input, output, qualityOfService) }
            catch { reaper.release(); throw error }
        } catch { ownership.reaped(id); throw error }
        self.id = id; self.ownership = ownership; self.reaper = reaper
    }
    deinit { stop() }
    var isRunning: Bool {
        guard !stopped else { return false }
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == 0
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        var info = siginfo_t(), result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) } while result < 0 && errno == EINTR
        // A failed observation never authorizes a signal; collection still owns
        // the reservation (ECHILD is handled by the reaper without a kill).
        if result == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        let ownership = ownership, id = id
        reaper.collect(pid) { ownership.reaped(id) }
    }
    private static func spawn(_ executable: URL, _ arguments: [String], _ input: Int32, _ output: Int32,
                              _ quality: QualityOfService?) throws -> pid_t {
        func check(_ code: Int32) throws { if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
        guard executable.isFileURL, ([executable.path] + arguments).allSatisfy({ !$0.contains("\0") }) else {
            throw AskFileReadError.unavailable
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes)); defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var empty = sigset_t(), defaults = sigset_t(); sigemptyset(&empty); sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &empty))
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        // Darwin's public spawn API only accepts these two reduced classes.
        // Foreground/default requests retain the normal process class; supplying
        // USER_INITIATED/INTERACTIVE here fails the entire launch with EINVAL.
        if quality == .background || quality == .utility {
            try check(posix_spawnattr_set_qos_class_np(&attributes,
                quality == .background ? QOS_CLASS_BACKGROUND : QOS_CLASS_UTILITY))
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + env).forEach { free($0) } }
        var pid: pid_t = 0
        try argv.withUnsafeBufferPointer { args in
            try env.withUnsafeBufferPointer { environment in
                try check(posix_spawn(&pid, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!)))
            }
        }
        return pid
    }
}
