import AppKit
import Darwin

/// Ends processes from the monitor: apps are asked to quit like ⌘Q, other
/// processes get SIGTERM (SIGKILL when forced). Only the user's own processes,
/// never the system's or Typeflux itself.
struct SystemProcessTerminator {
    enum Eligibility: Equatable {
        case allowed
        /// Root, another user's, or the kernel's.
        case system
        case typeflux
    }

    /// The user whose processes may be ended.
    var currentUID: UInt32 = getuid()
    var ownPID: Int32 = getpid()
    var application: (Int32) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    var signal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }

    func eligibility(of process: SystemProcess) -> Eligibility {
        if process.pid == ownPID { return .typeflux }
        if process.pid <= 1 || process.uid == 0 || process.uid != currentUID { return .system }
        return .allowed
    }

    /// Ends the process; false when it may not be ended or the system refused.
    @discardableResult
    func terminate(_ process: SystemProcess, force: Bool) -> Bool {
        guard eligibility(of: process) == .allowed else { return false }
        if let app = application(process.pid) {
            return force ? app.forceTerminate() : app.terminate()
        }
        return signal(process.pid, force ? SIGKILL : SIGTERM) == 0
    }
}
