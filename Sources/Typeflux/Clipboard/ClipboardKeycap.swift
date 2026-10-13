import SwiftUI

/// A small rounded key label such as `⌘P`.
struct ClipboardKeycap: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(TypefluxColor.secondaryLabel.color)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style), style: .continuous)
                .fill(colorScheme == .light ? TypefluxColor.controlBackground.color : Color.primary.opacity(0.1)))
            .overlay {
                if colorScheme == .light {
                    RoundedRectangle(cornerRadius: TypefluxRadius.textField.value(for: style), style: .continuous)
                        .strokeBorder(TypefluxColor.separator.color, lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
    }
}
