import SwiftUI

/// A starting point offered while a composer is empty: the same three as the
/// workspace's empty state.
struct AskSuggestion: Equatable, Identifiable {
    var key: String
    var systemImage: String
    /// Attaches the current screenshot before sending.
    var screenshot = false

    var id: String { key }
    var title: String { L(key) }
    var caption: String { L(key + ".caption") }

    static let all: [AskSuggestion] = [
        AskSuggestion(key: "ask.suggest.screen", systemImage: "display", screenshot: true),
        AskSuggestion(key: "ask.suggest.selection", systemImage: "character.bubble"),
        AskSuggestion(key: "ask.suggest.page", systemImage: "globe")
    ]

    /// Moves a highlight among the suggestions, wrapping at both ends.
    static func step(_ index: Int, by delta: Int, count: Int = all.count) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }
}

/// The launcher's suggestion list under its controls, as on the design board:
/// a hairline, three rows with an accent icon tile and a trailing caption, and
/// the keyboard hint. ↑/↓ move the highlight and Return sends it.
struct AskLauncherSuggestions: View {
    @Binding var highlighted: Int
    var onPick: (AskSuggestion) -> Void

    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let hintHeight: CGFloat = 24
    /// Everything this list adds to the launcher card.
    static var height: CGFloat {
        let rows = CGFloat(AskSuggestion.all.count)
        return 1 + listPadding * 2 + rows * rowHeight + (rows - 1) * rowSpacing + hintHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(AskSuggestion.all.enumerated()), id: \.element.id) { index, suggestion in
                    row(suggestion, highlighted: index == highlighted)
                        .onHover { if $0 { highlighted = index } }
                }
            }
            .padding(Self.listPadding)
            Text(L("ask.launcher.hint"))
                .font(.system(size: 11))
                .foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .frame(height: Self.hintHeight, alignment: .top)
                .accessibilityHidden(true)
        }
        .background(AskArrowKeyMonitor { delta in highlighted = AskSuggestion.step(highlighted, by: delta) })
    }

    private func row(_ suggestion: AskSuggestion, highlighted: Bool) -> some View {
        Button { onPick(suggestion) } label: {
            HStack(spacing: 12) {
                Image(systemName: suggestion.systemImage).font(.system(size: 12.5))
                    .foregroundStyle(AskTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(AskTheme.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(suggestion.title).font(.system(size: 13.5))
                    .foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(suggestion.caption).font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .background(highlighted ? AskTheme.hoverFill : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(suggestion.title)
        .accessibilityHint(suggestion.caption)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
