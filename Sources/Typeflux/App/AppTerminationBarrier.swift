import AppKit
import Darwin
import OSLog

/// Keeps cleanup alive during quit, but never leaves the application stuck forever.
@MainActor
final class AppTerminationBarrier {
    private var task: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var finished = false

    nonisolated init() {}

    func beginChecked(timeout: TimeInterval = 60, hardTimeoutGrace: TimeInterval = 5,
                      retryDelay: Duration = .seconds(1),
                      forceExit: @escaping @Sendable () -> Void = { kill(getpid(), SIGKILL) },
                      cleanup: @escaping @MainActor () async -> Bool,
                      reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard task == nil else { return .terminateLater }
        let watchdog = TerminationWatchdog(forceExit: forceExit)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout + hardTimeoutGrace) {
            watchdog.fire()
        }
        deadlineTask = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard !finished else { return }
            finished = true
            task?.cancel()
            Logger(subsystem: "ai.gulu.app.typeflux", category: "Shutdown").error("Quit deadline reached; exiting without confirmed cleanup")
            reply(true)
        }
        task = Task {
            while !Task.isCancelled && !finished {
                if await cleanup() {
                    guard !finished else { return }
                    finished = true
                    deadlineTask?.cancel()
                    watchdog.disarm()
                    reply(true)
                    return
                }
                guard !finished else { return }
                do { try await Task.sleep(for: retryDelay) } catch { return }
            }
        }
        return .terminateLater
    }

    func begin(cleanup: @escaping @MainActor () async -> Void,
               reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if task == nil {
            task = Task {
                await cleanup()
                reply()
            }
        }
        return .terminateLater
    }
}

/// The hard deadline must still work if AppKit's main thread stops responding.
private final class TerminationWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private let forceExit: @Sendable () -> Void

    init(forceExit: @escaping @Sendable () -> Void) { self.forceExit = forceExit }
    func disarm() { lock.withLock { armed = false } }
    func fire() {
        let shouldExit = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false
            return true
        }
        if shouldExit { forceExit() }
    }
}
