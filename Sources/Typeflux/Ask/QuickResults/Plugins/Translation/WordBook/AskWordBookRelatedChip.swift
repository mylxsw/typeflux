import SwiftUI

/// Related words retain their compact layout; light mode adds a white surface
/// and an accent outline on hover. Dark mode keeps the original quiet wash.
struct AskWordBookRelatedChip: View {
    let word: String
    let label: String?
    let onLookup: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    static func textColor(dark: Bool, hovering: Bool, label: Bool = false) -> Color {
        if !dark, hovering {
            return StudioTheme.accent
        }
        return label ? StudioTheme.textTertiary : StudioTheme.textPrimary
    }

    static func border(dark: Bool, hovering: Bool) -> Color {
        dark ? .clear : (hovering ? StudioTheme.accent : AskTheme.cardBorder)
    }

    var body: some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: AskWordBookStyle.controlCorner, style: .continuous)
        Button(action: onLookup) {
            HStack(spacing: 5) {
                if let label, !label.isEmpty {
                    Text(label).font(.system(size: 11))
                        .foregroundStyle(Self.textColor(dark: dark, hovering: hovering, label: true))
                }
                Text(word).font(.system(size: 12.5))
                    .foregroundStyle(Self.textColor(dark: dark, hovering: hovering))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.vertical, 5).frame(minHeight: 26)
            .background(dark ? AskTheme.hoverFill : .white, in: shape)
            .overlay(shape.strokeBorder(Self.border(dark: dark, hovering: hovering), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioInteractiveButtonStyle())
        .onHover { hovering = $0 }
        .help(L("ask.wordBook.lookUpWord", word))
    }
}
