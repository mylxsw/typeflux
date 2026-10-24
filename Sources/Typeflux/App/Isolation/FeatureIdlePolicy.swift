import Foundation

struct FeatureIdlePolicy {
    private var idleSince: TimeInterval?
    mutating func shouldRetire(role: FeatureRole, blocked: Bool, uptime: TimeInterval) -> Bool {
        let timeout: TimeInterval
        switch role {
        case .chat: timeout = 120
        case .background: timeout = 180
        // Screenshot pixels and editor views are released on dismissal. Keep the
        // prewarmed window owner ready for the next global shortcut.
        case .screenshot: idleSince = nil; return false
        default: idleSince = nil; return false
        }
        if blocked {
            idleSince = nil; return false
        }
        guard let idleSince else { idleSince = uptime; return false }
        return uptime >= idleSince && uptime - idleSince >= timeout
    }
}
