import SwiftUI

/// The slash command list: grouped rows with the highlighted one tinted,
/// a header naming the open submenu, and the keys that drive it.
struct AskCommandPaletteView: View {
    let state: AskCommandPaletteState
    var compact = false
    var maximumHeight: CGFloat?
    var onPick: (Int) -> Void
    var onHighlight: (Int) -> Void
    var onManage: (() -> Void)?
    @Environment(\.interfaceStyle) private var style

    static let rowHeight: CGFloat = 44
    static let groupHeight: CGFloat = 26
    /// Header (32), footer (36), the list's vertical padding (8) and the dividers.
    static let chromeHeight: CGFloat = 78
    static let maximumListHeight: CGFloat = 300

    /// Height of the whole palette for `state`, so the launcher can size its panel.
    static func height(for state: AskCommandPaletteState, compact: Bool = false,
                       maximumHeight: CGFloat? = nil) -> CGFloat {
        let chrome: CGFloat = compact ? 24 : chromeHeight
        let groups = compact ? 0 : groupStarts(state).count
        let list = CGFloat(state.rows.count) * rowHeight + CGFloat(groups) * groupHeight
        let limit = maximumHeight.map { max(rowHeight, $0 - chrome) } ?? (compact ? rowHeight : maximumListHeight)
        return chrome + min(list, min(limit, maximumListHeight))
    }

    /// Row indexes that begin a group. Groups label the full list only; a search
    /// or a submenu is one ranked list.
    static func groupStarts(_ state: AskCommandPaletteState) -> Set<Int> {
        guard state.parent == nil, state.rows.allSatisfy({ $0.score == 1 }) else { return [] }
        var starts = Set<Int>()
        for index in state.rows.indices where index == 0 || state.rows[index - 1].command.group != state.rows[index].command.group {
            starts.insert(index)
        }
        return starts
    }

    var body: some View {
        let starts = compact ? [] : Self.groupStarts(state)
        TypefluxGlassContainer(radius: .spotlightResults, placement: .inWindow) {
            content(starts: starts)
        }
        .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.spotlightResults.value(for: style)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.command.title"))
        .accessibilityIdentifier("ask.command.palette")
    }

    private func content(starts: Set<Int>) -> some View {
        VStack(spacing: 0) {
            header
            if !compact { Divider().opacity(0.5) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.rows.enumerated()), id: \.offset) { index, match in
                            if starts.contains(index) {
                                Text(match.command.group.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                                    .frame(height: Self.groupHeight, alignment: .bottomLeading)
                                    .padding(.horizontal, 12)
                            }
                            Button { onPick(index) } label: {
                                AskCommandRow(match: match, highlighted: index == state.highlighted)
                            }
                            .buttonStyle(.plain)
                            .disabled(!match.command.enabled)
                            .accessibilityLabel(match.command.title.isEmpty ? match.command.name : match.command.title)
                            .accessibilityValue(match.command.plain ? match.command.name : "/" + match.command.name)
                            .accessibilityHint(match.command.disabledReason ?? match.command.detail ?? "")
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, compact ? 0 : 4)
                }
                .frame(maxHeight: Self.height(for: state, compact: compact, maximumHeight: maximumHeight)
                    - (compact ? 24 : Self.chromeHeight))
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.highlighted) { index in proxy.scrollTo(index) }
            }
            if !compact {
                Divider().opacity(0.5)
                footer
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.parent == nil ? "command" : "chevron.left")
                .font(.subheadline.weight(.semibold))
            if let parent = state.parent {
                Text(verbatim: "/" + parent.name).font(.callout.weight(.semibold).monospaced())
                Text(parent.title).font(.callout)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
            } else {
                Text(L("ask.command.title")).font(.callout.weight(.semibold))
            }
            Spacer()
        }
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .padding(.horizontal, 14)
        .frame(height: compact ? 24 : 32)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L("ask.command.keys")).lineLimit(1)
            Spacer()
            if let onManage {
                Button(L("ask.command.manage"), action: onManage)
                    .buttonStyle(.plain)
                    .foregroundStyle(TypefluxColor.accent.color)
            }
        }
        .font(.subheadline)
        .foregroundStyle(TypefluxColor.secondaryLabel.color)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}
