import AppKit
import SwiftUI

/// A search that found nothing: Ask AI stays first and takes Return, a line says
/// nothing matched, and the web and file contents are offered instead.
struct AskLauncherNoMatchView: View {
    var query: String
    /// The search covered applications or files; otherwise nothing is said about matches.
    var searched: Bool
    var destinations: [AskLauncherNoMatch.Destination]
    @Binding var highlighted: Int?
    var palette: AskOrbPalette = .brand
    var viewportHeight: CGFloat = 420
    var onAskAI: () -> Void
    var onPick: (AskLauncherNoMatch.Destination) -> Void

    @State private var pointer = AskSearchPointer(position: NSEvent.mouseLocation)

    var body: some View {
        VStack(alignment: .leading, spacing: AskLauncherSuggestions.rowSpacing) {
            Rectangle().fill(AskTheme.launcherSeparator).frame(height: 1).padding(.horizontal, 6)
                .padding(.bottom, 4)
            Spacer(minLength: 0)
            let layout = AskLauncherWelcome.layout(viewport: viewportHeight)
            VStack(spacing: 16) {
                if layout.orbSize > 0 {
                    AskConversationOrb(size: layout.orbSize, palette: palette)
                }
                Text(L("ask.empty"))
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityIdentifier("ask.launcher.empty.title")
                    .foregroundStyle(StudioTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
            row(symbol: "sparkles", title: L("ask.launcher.noMatch.askAI", query), detail: nil,
                selected: highlighted == nil, number: nil, action: onAskAI)
                .onContinuousHover { phase in
                    if case .active = phase, pointer.moved(to: NSEvent.mouseLocation) { highlighted = nil }
                }
            // Search becomes pending on every edit. Keep its status line in the
            // layout so the centered orb and destinations never move with it.
            Text(L("ask.launcher.noMatch.message", query))
                .font(.system(size: 12))
                .foregroundStyle(AskTheme.launcherMetaText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, AskLauncherSuggestions.contentInset)
                .padding(.vertical, 8)
                .opacity(searched ? 1 : 0)
                .accessibilityHidden(!searched)
            if !destinations.isEmpty {
                Text(L("ask.launcher.noMatch.section")).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(AskTheme.launcherMetaText)
                    .padding(.horizontal, AskLauncherSuggestions.contentInset)
                    .padding(.top, 6)
                    .padding(.bottom, AskLauncherSuggestions.headerBottomGap)
                ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                    row(symbol: destination.symbol, title: destination.title, detail: destination.detail,
                        selected: highlighted == index, number: index + 1) { onPick(destination) }
                        .onContinuousHover { phase in
                            if case .active = phase, pointer.moved(to: NSEvent.mouseLocation) { highlighted = index }
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AskLauncherSuggestions.listPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AskLauncherHomeKeyMonitor { key in handle(key) })
        .onChange(of: destinations.count) { count in
            if let index = highlighted, index >= count { highlighted = nil }
        }
    }

    private func row(symbol: String, title: String, detail: String?, selected: Bool, number: Int?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(AskTheme.launcherTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.system(size: 13.5)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let detail {
                    Text(detail).font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, AskLauncherSuggestions.contentInset)
            .frame(height: AskLauncherSuggestions.rowHeight)
            .background(selected ? AskTheme.launcherSelection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(AskTheme.launcherSelectionEdge, lineWidth: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(AskLauncherNumberBadge(number: number))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func handle(_ key: AskLauncherHomeKeyMonitor.Key) -> Bool {
        guard !destinations.isEmpty else { return false }
        switch key {
        case let .vertical(delta):
            if delta < 0, highlighted == nil { return false }
            highlighted = AskLauncherNoMatch.move(highlighted, by: delta, count: destinations.count)
            return true
        case let .number(number):
            guard destinations.indices.contains(number - 1) else { return false }
            onPick(destinations[number - 1])
            return true
        case .horizontal, .tab:
            return false
        }
    }
}
