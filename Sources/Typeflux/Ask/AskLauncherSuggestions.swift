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

    /// Moves a highlight among the suggestions, wrapping at both ends and
    /// passing over the ones that cannot run.
    static func step(_ index: Int, by delta: Int, count: Int = all.count, skipping disabled: Set<Int> = []) -> Int {
        guard count > 0 else { return 0 }
        var next = index
        for _ in 0 ..< count {
            next = ((next + delta) % count + count) % count
            if !disabled.contains(next) { return next }
        }
        return index
    }

    /// The highlight to start from: the given one, or the next that can run.
    static func available(_ index: Int, count: Int = all.count, skipping disabled: Set<Int>) -> Int {
        disabled.contains(index) ? step(index, by: 1, count: count, skipping: disabled) : index
    }
}

/// The launcher's suggestion list under its editor: a hairline and three rows
/// with an accent icon tile and a trailing caption. The keyboard hint sits in
/// the launcher's bottom bar. ↑/↓ move the highlight and Return sends it.
struct AskLauncherSuggestions: View {
    @Binding var highlighted: Int
    /// What the screenshot suggestion can do with the launcher's model.
    var screenshot: AskScreenshotSuggestion = .ready
    var onPick: (AskSuggestion) -> Void

    /// Rows that cannot run: the screenshot one when no model here can read images.
    static func disabled(screenshot: AskScreenshotSuggestion) -> Set<Int> {
        guard !screenshot.enabled else { return [] }
        return Set(AskSuggestion.all.indices.filter { AskSuggestion.all[$0].screenshot })
    }

    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    /// Everything this list adds to the launcher card.
    static var height: CGFloat {
        let rows = CGFloat(AskSuggestion.all.count)
        return 1 + listPadding * 2 + rows * rowHeight + (rows - 1) * rowSpacing
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AskTheme.separator).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(AskSuggestion.all.enumerated()), id: \.element.id) { index, suggestion in
                    let enabled = !disabled.contains(index)
                    row(suggestion, highlighted: enabled && index == highlighted, enabled: enabled)
                        .onHover { if $0, enabled { highlighted = index } }
                }
            }
            .padding(Self.listPadding)
        }
        .background(AskArrowKeyMonitor { delta in
            highlighted = AskSuggestion.step(highlighted, by: delta, skipping: disabled)
        })
        .onAppear { highlighted = AskSuggestion.available(highlighted, skipping: disabled) }
        .onChange(of: screenshot) { _ in highlighted = AskSuggestion.available(highlighted, skipping: disabled) }
    }

    private var disabled: Set<Int> { Self.disabled(screenshot: screenshot) }

    private func caption(_ suggestion: AskSuggestion) -> String {
        suggestion.screenshot ? screenshot.caption(default: suggestion.caption) : suggestion.caption
    }

    private func row(_ suggestion: AskSuggestion, highlighted: Bool, enabled: Bool) -> some View {
        let tint = enabled ? AskTheme.accent : StudioTheme.textTertiary
        return Button { onPick(suggestion) } label: {
            HStack(spacing: 12) {
                Image(systemName: suggestion.systemImage).font(.system(size: 12.5))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(suggestion.title).font(.system(size: 13.5))
                    .foregroundStyle(enabled ? StudioTheme.textPrimary : StudioTheme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(caption(suggestion)).font(.system(size: 11.5))
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
        .disabled(!enabled)
        .accessibilityLabel(suggestion.title)
        .accessibilityHint(caption(suggestion))
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}
