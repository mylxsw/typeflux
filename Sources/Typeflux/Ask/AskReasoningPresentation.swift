import SwiftUI

/// Reasoning levels carry semantic emphasis independently of the window style.
enum AskReasoningPresentation {
    static let topColor = Color(nsColor: .systemPurple)

    static func color(_ effort: AskReasoningEffort, in levels: [AskReasoningEffort], defaultColor: Color) -> Color {
        if effort == .providerDefault { return defaultColor }
        return effort.isTop(in: levels) ? topColor : TypefluxColor.accent.color
    }
}
