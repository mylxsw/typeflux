import SwiftUI

public enum TypefluxTone: String, CaseIterable, Sendable {
    case neutral, accent, success, warning, danger, inactive

    var color: Color {
        switch self {
        case .neutral, .inactive: TypefluxColor.secondaryLabel.color
        case .accent: TypefluxColor.accent.color
        case .success: TypefluxColor.success.color
        case .warning: TypefluxColor.warning.color
        case .danger: TypefluxColor.danger.color
        }
    }
}
