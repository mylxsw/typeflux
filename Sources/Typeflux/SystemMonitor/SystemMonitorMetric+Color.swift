import SwiftUI

extension SystemMonitorMetric {
    var color: Color {
        switch self {
        case .cpu: TypefluxColor.accent.color
        case .memory: Color(nsColor: .systemPurple)
        case .disk: Color(nsColor: .systemTeal)
        case .network: TypefluxColor.success.color
        }
    }
}
