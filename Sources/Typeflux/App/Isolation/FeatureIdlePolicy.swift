import Foundation

struct FeatureIdlePolicy {
    private var idleSince: TimeInterval?
    mutating func shouldRetire(role: FeatureRole, blocked: Bool, uptime: TimeInterval) -> Bool {
        let timeout: TimeInterval
        switch role {
        case .chat: timeout = 120
        case .screenshot, .background: timeout = 180
        default: idleSince = nil; return false
        }
        if blocked {
            idleSince = nil; return false
        }
        guard let idleSince else { idleSince = uptime; return false }
        return uptime >= idleSince && uptime - idleSince >= timeout
    }
}
