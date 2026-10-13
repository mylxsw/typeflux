import TypefluxUI

extension AgentCapabilityStatus.Level {
    var tone: TypefluxTone {
        switch self {
        case .ready: .success
        case .attention: .warning
        case .off: .inactive
        }
    }
}
