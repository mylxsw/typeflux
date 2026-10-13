import SwiftUI

/// Scene assignments are metadata, rather than attachment tokens.
struct ModelUsageBadge: View {
    let text: String
    var accent = false

    var body: some View {
        Text(text).font(.subheadline)
            .foregroundStyle(accent ? TypefluxColor.accent.color : TypefluxColor.secondaryLabel.color)
            .lineLimit(1).fixedSize()
    }
}
