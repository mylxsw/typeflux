import SwiftUI

/// The legacy Studio sidebar owns its selection drawing independently of the libraries.
/// Light uses a raised block; dark uses the existing glass wash or Classic fill.
struct StudioSidebarRowBackground: ViewModifier {
    var selected: Bool
    var corner: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.interfaceStyle) private var style

    static func usesRaisedBlock(selected: Bool, dark: Bool) -> Bool { selected && !dark }

    @ViewBuilder
    func body(content: Content) -> some View {
        if Self.usesRaisedBlock(selected: selected, dark: colorScheme == .dark) {
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            content
                .background(shape.fill(StudioTheme.sidebarSelection)
                    .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1))
                .overlay(shape.strokeBorder(StudioTheme.sidebarSelectionStroke, lineWidth: 1))
        } else {
            content.background {
                if selected {
                    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
                    if style.usesGlass {
                        shape.fill(AskTheme.accent.opacity(0.18))
                            .overlay(shape.strokeBorder(AskTheme.accent.opacity(0.4), lineWidth: 0.5))
                    } else {
                        shape.fill(AskClassic.selection)
                    }
                }
            }
        }
    }
}
