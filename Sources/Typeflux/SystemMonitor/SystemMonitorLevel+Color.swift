import SwiftUI

extension SystemMonitorLevel {
    var color: Color? {
        switch self {
        case .normal: nil
        case .elevated: TypefluxColor.warning.color
        case .critical: TypefluxColor.danger.color
        }
    }
}
