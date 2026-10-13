import SwiftUI

/// An inline explanation for a capability that has no configuration yet.
struct AgentInfoNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(TypefluxColor.accent.color)
            Text(text).foregroundStyle(TypefluxColor.secondaryLabel.color).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
