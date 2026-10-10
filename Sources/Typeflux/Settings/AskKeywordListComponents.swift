import SwiftUI

extension AskKeywordKind {
    /// The tile colour that tells the kinds apart in the list.
    var tint: Color {
        switch self {
        case .translate: StudioTheme.accent
        case .prompt: Color.purple
        case .web: StudioTheme.success
        case .files: Color.teal
        case .tabs: Color.orange
        case .bookmarks: Color.blue
        case .chat: Color.blue
        case .prefix: Color.indigo
        case .setting: Color.gray
        case .history: Color.blue
        case .clip: Color.teal
        case .system: Color.gray
        case .workflow: Color.orange
        }
    }
}

/// The kind's symbol on a tinted tile.
struct AskKeywordKindTile: View {
    let kind: AskKeywordKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(kind.tint)
            .frame(width: size, height: size)
            .background(kind.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// A keyword as the launcher shows it: monospaced on a small plate.
struct AskKeywordListChip: View {
    let keyword: String
    var isDefault = false

    var body: some View {
        Text(keyword)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(isDefault ? ModelVisualStyle.accent : StudioTheme.textSecondary)
            .padding(.horizontal, 7).frame(height: 21)
            .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
    }
}

/// A compact menu for all plugin kinds, each with its count.
struct AskKeywordFilterBar: View {
    @Binding var selection: AskKeywordKind?
    let counts: [AskKeywordKind?: Int]

    private var options: [(AskKeywordKind?, String)] {
        [(nil, L("ask.settings.keywords.filter.all"))] + AskKeywordKind.editableKinds.map { ($0, $0.title) }
    }

    var body: some View {
        SettingsMenuPicker(title: options.first { $0.0 == selection }?.1 ?? L("ask.settings.keywords.filter.all"),
                           options: options.map { (label: "\($0.1) · \(counts[$0.0] ?? 0)", value: $0.0) },
                           selection: $selection)
            .accessibilityIdentifier("ask.settings.keywords.filter")
    }
}

/// A whole section header is clickable, including its count and disclosure arrow.
struct AskKeywordSectionHeader: View {
    let section: AskKeywordSection
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).frame(width: 18).foregroundStyle(ModelVisualStyle.accent)
                Text(section.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.textPrimary)
                Text(String(count)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(StudioTheme.textSecondary.opacity(0.035))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(L(expanded ? "ask.settings.keywords.expanded" : "ask.settings.keywords.collapsed"))
        .accessibilityIdentifier("ask.settings.keywords.section." + section.rawValue)
    }
}

/// Function and description share one flexible column; keywords wrap underneath.
/// This keeps long aliases readable even in a narrow settings pane.
struct AskKeywordRowView: View {
    let row: AskKeywordListRow
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AskKeywordKindTile(kind: row.kind, size: 28).padding(.top, 2)
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StudioTheme.textPrimary)
                    Text(row.summary).font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if row.keyword.isEmpty {
                        Text(L("ask.system.setKeyword")).font(.system(size: 12))
                            .foregroundStyle(ModelVisualStyle.accent)
                    } else {
                        AskFlowLayout(spacing: 5) {
                            ForEach(Array(row.source.allKeywords.enumerated()), id: \.offset) { index, word in
                                AskKeywordListChip(keyword: word, isDefault: index == 0)
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
            Toggle("", isOn: Binding(get: { row.enabled }, set: { _ in toggle() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).padding(.top, 2)
                .disabled(row.keyword.isEmpty)
                .accessibilityLabel(L("ask.settings.keywords.enabled") + " " + row.keyword)
        }
        .opacity(row.enabled ? 1 : 0.5)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hovering ? StudioTheme.textSecondary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.settings.keywords.row." + row.keyword)
    }
}

/// An entry in the "Add keyword" menu: the kind's tile, its name and what it does.
struct AskKeywordMenuItem: View {
    let kind: AskKeywordKind
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AskKeywordKindTile(kind: kind, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovering ? Color.white : StudioTheme.textPrimary)
                    Text(kind.hint).font(.system(size: 11.5))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : StudioTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovering ? ModelVisualStyle.accent : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("ask.settings.keywords.add." + kind.rawValue)
    }
}
