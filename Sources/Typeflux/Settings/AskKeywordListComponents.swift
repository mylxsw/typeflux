import SwiftUI

extension AskKeywordKind {
    /// The tile colour that tells the kinds apart in the list.
    var tint: Color {
        switch self {
        case .translate: TFColors.accent
        case .prompt: Color.purple
        case .web: TFColors.success
        case .apps, .files, .semanticFiles: Color.teal
        case .tabs: Color.orange
        case .bookmarks: Color.blue
        case .chat, .quickAsk: Color.blue
        case .prefix: Color.indigo
        case .setting: Color.gray
        case .history: Color.blue
        case .clip: Color.teal
        case .emoji: Color.orange
        case .calendar: Color.red
        case .kill: Color.red
        case .system: Color.gray
        case .workflow: Color.orange
        }
    }
}

/// The kind's symbol on a soft tinted tile.
struct AskKeywordKindTile: View {
    let kind: AskKeywordKind
    var size: CGFloat = 24

    var body: some View {
        TFIconTile(systemImage: kind.symbol, tint: kind.tint, size: size, style: .soft)
    }
}

/// A keyword as the launcher shows it: a monospaced tag, accent for the default keyword.
struct AskKeywordListChip: View {
    let keyword: String
    var isDefault = false
    var query = ""

    var body: some View {
        TFTag(text: keyword, monospaced: true, tint: isDefault ? TFColors.accent : nil, query: query)
    }
}

/// Function and description share one flexible column; keywords wrap underneath.
/// This keeps long aliases readable even in a narrow settings pane.
struct AskKeywordRowView: View {
    let row: AskKeywordListRow
    var query = ""
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AskKeywordKindTile(kind: row.kind, size: TFMetrics.iconTileSize).padding(.top, 2)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 5) {
                    TFHighlightedText(text: row.name, query: query)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(TFColors.textPrimary)
                    TFHighlightedText(text: row.summary, query: query)
                        .font(.system(size: 12)).foregroundStyle(TFColors.textSecondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if row.keyword.isEmpty {
                        Text(L("ask.system.setKeyword")).font(.system(size: 12)).foregroundStyle(TFColors.accent)
                    } else {
                        TFFlowLayout(spacing: 5) {
                            ForEach(Array(row.source.allKeywords.enumerated()), id: \.offset) { index, word in
                                AskKeywordListChip(keyword: word, isDefault: index == 0, query: query)
                                    .help(L(index == 0 ? "ask.settings.keywords.defaultKeyword" :
                                            "ask.settings.keywords.alias"))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.settings.keywords.edit." + row.keyword)
            TFSwitch(title: L("ask.settings.keywords.enabled") + " " + row.keyword,
                     isOn: Binding(get: { row.enabled }, set: { _ in toggle() }))
                .padding(.top, 2)
                .disabled(row.keyword.isEmpty)
        }
        .opacity(row.enabled ? 1 : 0.5)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hovering ? TFColors.hoverOverlay : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.settings.keywords.row." + row.keyword)
    }
}
