import Darwin
import Foundation

/// Bounds live children, including children stuck in an uninterruptible kernel call.
/// Reaping never blocks a caller and never signals a PID after it has been reaped.
final class OwnedProcessReaper: @unchecked Sendable {
    static let shared = OwnedProcessReaper()
    private let lock = NSLock()
    private let capacity: Int
    private var active = 0
    private var pending = Set<pid_t>()
    private var completions: [pid_t: @Sendable () -> Void] = [:]
    private var timer: DispatchSourceTimer?
    private let reaped: @Sendable (pid_t) -> Bool
    private let schedulesReaping: Bool

    init(capacity: Int = 16, schedulesReaping: Bool = true,
         reaped: @escaping @Sendable (pid_t) -> Bool = { OwnedProcessReaper.reap($0) }) {
        self.capacity = capacity
        self.schedulesReaping = schedulesReaping
        self.reaped = reaped
    }

    deinit { timer?.cancel() }

    func reserve() throws {
        lock.lock(); defer { lock.unlock() }
        guard active < capacity else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EAGAIN)) }
        active += 1
    }

    /// Releases a reservation when no process was spawned or another owner reaped it.
    func release() {
        lock.lock(); defer { lock.unlock() }
        active -= 1
    }

    /// Takes ownership of a direct child after the caller has sent its final signal.
    func collect(_ pid: pid_t, onReaped: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if reaped(pid) {
            active -= 1
            lock.unlock()
            onReaped()
            return
        }
        pending.insert(pid)
        completions[pid] = onReaped
        defer { lock.unlock() }
        guard schedulesReaping, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.collectPending() }
        self.timer = timer
        timer.resume()
    }

    func collectPending() {
        lock.lock()
        var completed: [@Sendable () -> Void] = []
        for pid in Array(pending) where reaped(pid) {
            pending.remove(pid)
            if let completion = completions.removeValue(forKey: pid) { completed.append(completion) }
            active -= 1
        }
        if pending.isEmpty {
            timer?.cancel(); timer = nil
        }
        lock.unlock()
        for completion in completed { completion() }
    }

    private static func reap(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == pid || (result < 0 && errno == ECHILD)
    }
}
