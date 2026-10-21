import SwiftUI

/// Notebook and word book share the same column geometry and collapse point.
struct AskLibraryLayout {
    static let sidebarWidth: CGFloat = 232
    static let maximumListWidth: CGFloat = 320
    static let sidebarCollapseWidth: CGFloat = 1100
    static let readingWidth: CGFloat = 700

    static func titleSize(compact: Bool) -> CGFloat { compact ? 21 : 26 }

    let width: CGFloat
    var sidebarInline: Bool { width >= Self.sidebarCollapseWidth }
    var sidebarWidth: CGFloat { sidebarInline ? Self.sidebarWidth : 0 }
    var listWidth: CGFloat { min(Self.maximumListWidth, max(240, width * 0.26)) }
    var detailWidth: CGFloat { max(0, width - sidebarWidth - listWidth) }
}

/// A search field is part of its column, rather than a second glass panel.
private struct AskLibrarySearchSurface: ViewModifier {
    var focused: Bool
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, style.usesGlass ? 10 : 8)
            .frame(height: style.ask.searchFieldHeight)
            .background(hovering || focused ? AskTheme.pressFill : AskTheme.hoverFill,
                        in: RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous))
            .overlay {
                if style.usesGlass {
                    RoundedRectangle(cornerRadius: style.ask.searchFieldCorner, style: .continuous)
                        .strokeBorder(AskTheme.separator, lineWidth: 0.5)
                }
            }
            .onHover { hovering = $0 }
    }
}

private struct AskLibraryActionSurface: ViewModifier {
    @Environment(\.interfaceStyle) private var style

    func body(content: Content) -> some View {
        content
            .askContentCard(corner: style.usesGlass ? 20 : 10, opaqueFill: AskTheme.glassFill)
            .padding(.bottom, 16)
            .accessibilityElement(children: .contain)
    }
}

extension View {
    func askLibrarySearchSurface(focused: Bool) -> some View {
        modifier(AskLibrarySearchSurface(focused: focused))
    }

    func askLibraryActionSurface() -> some View {
        modifier(AskLibraryActionSurface())
    }
}

/// The same adaptive action button in either library's floating bar.
struct AskLibraryBarButton: View {
    var title: String
    var symbol: String
    var key: String?
    var danger = false
    var compact = false
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).aiSymbolTint(symbol).font(.system(size: 11.5))
                if !compact { Text(title).font(.system(size: 12.5)).lineLimit(1) }
            }
            .fixedSize()
            .foregroundStyle(danger ? StudioTheme.danger : StudioTheme.textPrimary)
            .padding(.horizontal, 9).frame(height: 28)
            .background(hovering ? AskTheme.hoverFill : Color.clear, in: style.controlShape(height: 28))
            .contentShape(style.controlShape(height: 28))
        }
        .buttonStyle(AskPressableStyle())
        .onHover { hovering = $0 }
        .help(title + (key.map { " " + $0 } ?? ""))
        .accessibilityLabel(title)
    }
}
