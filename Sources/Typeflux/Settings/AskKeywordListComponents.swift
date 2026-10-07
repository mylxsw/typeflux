import SwiftUI

extension AskKeywordKind {
    /// The tile colour that tells the kinds apart in the list.
    var tint: Color {
        switch self {
        case .translate: StudioTheme.accent
        case .prompt: Color.purple
        case .web: StudioTheme.success
        case .files: Color.teal
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

    var body: some View {
        Text(keyword)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(StudioTheme.textPrimary)
            .padding(.horizontal, 7).frame(height: 21)
            .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ModelVisualStyle.border))
            .lineLimit(1).fixedSize()
    }
}

/// All · Translate · AI prompt · Web search · Workflows, each with its count.
struct AskKeywordFilterBar: View {
    @Binding var selection: AskKeywordKind?
    let counts: [AskKeywordKind?: Int]

    private var options: [(AskKeywordKind?, String)] {
        [(nil, L("ask.settings.keywords.filter.all"))] + AskKeywordKind.allCases.map { ($0, $0.title) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { kind, title in
                let selected = selection == kind
                Button { selection = kind } label: {
                    HStack(spacing: 4) {
                        Text(title).foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                        Text("\(counts[kind] ?? 0)").foregroundStyle(StudioTheme.textTertiary)
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? StudioTheme.selectionSurfaceRaised : Color.clear)
                            .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("ask.settings.keywords.filter." + (kind?.rawValue ?? "all"))
            }
        }
        .padding(2)
        .background(ModelVisualStyle.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(ModelVisualStyle.border))
        .fixedSize()
    }
}

/// A kind's heading inside the list card, with what the kind does.
struct AskKeywordGroupHeader: View {
    let kind: AskKeywordKind
    var first = false

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                Rectangle().fill(ModelVisualStyle.divider).frame(height: 1)
            }
            HStack(spacing: 6) {
                Text(kind.title).font(.system(size: 11.5, weight: .semibold))
                Text("· " + kind.hint).font(.system(size: 11.5))
            }
            .foregroundStyle(StudioTheme.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).frame(height: 32)
            .background(StudioTheme.textSecondary.opacity(0.04))
        }
    }
}

/// One keyword: chip, kind and name, one line on what it does, and its switch.
/// The whole row opens the editor; workflow rows open the workflow editor instead.
struct AskKeywordRowView: View {
    let row: AskKeywordListRow
    let toggle: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AskKeywordListChip(keyword: row.keyword).frame(width: 96, alignment: .leading)
            HStack(spacing: 9) {
                AskKeywordKindTile(kind: row.kind)
                Text(row.name).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            Text(row.summary)
                .font(.system(
                    size: row.monospacedSummary ? 11.5 : 12,
                    design: row.monospacedSummary ? .monospaced : .default
                ))
                .foregroundStyle(row.shadowed ? StudioTheme.warning : StudioTheme.textTertiary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.workflowID != nil {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 38)
                    .help(L("ask.settings.keywords.summary.workflow"))
            } else {
                Toggle("", isOn: Binding(get: { row.enabled }, set: { _ in toggle() }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L("ask.settings.keywords.enabled") + " " + row.keyword)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
                .opacity(hovering ? 1 : 0)
        }
        .opacity(row.enabled ? 1 : 0.5)
        .padding(.leading, 16).padding(.trailing, 14).frame(height: 46)
        .background(hovering ? StudioTheme.textSecondary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
