import Darwin
import Foundation

/// One serial reader lineage. Replacements retain the same admission until both
/// the old child and its synchronous host callback have retired.
final class AskFileReaderOwnership: @unchecked Sendable {
    private let condition = NSLock()
    private var current: UUID?
    private var hosts = 0
    private var collected = false
    private var generation: UUID?
    private var lifecycle: ModuleWorkerGate?
    private var stopChild: (@Sendable () -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    private let requiresLifecycle: Bool
    private var invalidate: (@Sendable () -> Void)?

    init(requiresLifecycle: Bool = false) { self.requiresLifecycle = requiresLifecycle }
    func bind(_ gate: ModuleWorkerGate, invalidate: @escaping @Sendable () -> Void) -> Bool {
        condition.withLock {
            guard lifecycle == nil, current == nil else { return false }
            lifecycle = gate; self.invalidate = invalidate; return true
        }
    }
    var permitsWork: Bool { condition.withLock { lifecycle.map { (try? $0.admit()) != nil } ?? !requiresLifecycle } }
    func permits(_ id: UUID) -> Bool {
        condition.withLock { current == id && !collected && (lifecycle.map { $0.permits(generation) } ?? !requiresLifecycle) }
    }
    func attach(_ id: UUID, stop: @escaping @Sendable () -> Void) {
        let cancel = condition.withLock {
            guard current == id else { return true }
            stopChild = stop
            return lifecycle.map { !$0.permits(generation) } ?? requiresLifecycle
        }
        if cancel { stop() }
    }
    func failed(configuration: Bool) {
        let callback = condition.withLock { () -> (@Sendable () -> Void)? in
            guard let lifecycle, lifecycle.permits(generation) else { return nil }
            lifecycle.failed(generation, configuration: configuration); return invalidate
        }
        callback?()
    }
    func succeeded() { condition.withLock { lifecycle?.succeeded(generation) } }
    func stopOwned() {
        let callbacks = condition.withLock { (invalidate, stopChild) }
        callbacks.0?(); callbacks.1?()
    }
    func retireManaged() async {
        stopOwned()
        await waitUntilRetired()
    }
    func waitUntilRetired() async {
        await withCheckedContinuation { continuation in
            let done = condition.withLock {
                guard current != nil else { return true }
                waiter = continuation; return false
            }
            if done { continuation.resume() }
        }
    }

    func reserve(isCancelled: () -> Bool) throws -> UUID {
        // Cancellation may query this lineage. Never invoke caller code while
        // holding its lock, including during the short collection grace.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while true {
            if isCancelled() { throw AskFileReadError.cancelled }
            let id = try condition.withLock { () throws -> UUID? in
                guard current == nil else { return nil }
                if let lifecycle { generation = try lifecycle.admit() }
                else if requiresLifecycle { throw AskFileReadError.unavailable }
                let id = UUID(); current = id; hosts = 0; collected = false; return id
            }
            if let id { return id }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw AskFileReadError.unavailable }
            usleep(10_000)
        }
    }
    func begin(_ id: UUID) throws {
        condition.lock(); defer { condition.unlock() }
        guard current == id, !collected else { throw AskFileReadError.unavailable }
        hosts += 1
    }
    func end(_ id: UUID) { update(id, host: true) }
    func reaped(_ id: UUID) { update(id, host: false) }
    private func update(_ id: UUID, host: Bool) {
        condition.lock()
        guard current == id else { condition.unlock(); return }
        if host { hosts -= 1 } else { collected = true }
        var done: CheckedContinuation<Void, Never>?
        if collected && hosts == 0 { current = nil; stopChild = nil; done = waiter; waiter = nil }
        let gate = lifecycle
        condition.unlock()
        gate?.changed(); done?.resume()
    }
    var isOccupied: Bool {
        condition.lock(); defer { condition.unlock() }; return current != nil
    }
}

/// POSIX ownership keeps the PID reserved until the last signal. Foundation's
/// asynchronous Process reaper must not race a later raw kill(pid).
final class AskFileReaderProcess: @unchecked Sendable {
    private let lock = NSLock()
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
        ownership.attach(id) { [weak self] in self?.stop() }
    }
    deinit { stop() }
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == 0
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
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
