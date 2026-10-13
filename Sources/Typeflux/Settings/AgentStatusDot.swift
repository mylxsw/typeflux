import SwiftUI

/// Small coloured dot for a capability state.
struct AgentStatusDot: View {
    let level: AgentCapabilityStatus.Level

    var body: some View {
        Circle()
            .fill(color.opacity(level == .off ? 0.5 : 1))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch level {
        case .ready: TypefluxColor.success.color
        case .attention: TypefluxColor.warning.color
        case .off: TypefluxColor.tertiaryLabel.color
        }
    }
}
