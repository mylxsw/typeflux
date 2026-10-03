import SwiftUI

/// The slash command list: grouped rows with the highlighted one tinted,
/// a header naming the open submenu, and the keys that drive it.
struct AskCommandPaletteView: View {
    let state: AskCommandPaletteState
    var onPick: (Int) -> Void
    var onHighlight: (Int) -> Void
    var onManage: (() -> Void)?

    static let rowHeight: CGFloat = 44
    static let groupHeight: CGFloat = 26
    /// Header (32), footer (36), the list's vertical padding (8) and the dividers.
    static let chromeHeight: CGFloat = 78
    static let maximumListHeight: CGFloat = 300

    /// Height of the whole palette for `state`, so the launcher can size its panel.
    static func height(for state: AskCommandPaletteState) -> CGFloat {
        let groups = groupStarts(state).count
        let list = CGFloat(state.rows.count) * rowHeight + CGFloat(groups) * groupHeight
        return chromeHeight + min(list, maximumListHeight)
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
        let starts = Self.groupStarts(state)
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(state.rows.enumerated()), id: \.offset) { index, match in
                            if starts.contains(index) {
                                Text(match.command.group.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .frame(height: Self.groupHeight, alignment: .bottomLeading)
                                    .padding(.horizontal, 12)
                            }
                            AskCommandRow(match: match, highlighted: index == state.highlighted)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(index) }
                                .onHover { if $0 { onHighlight(index) } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: Self.maximumListHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.highlighted) { index in proxy.scrollTo(index) }
            }
            Divider().opacity(0.5)
            footer
        }
        .background(AskTheme.popoverSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AskTheme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("ask.command.title"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.parent == nil ? "command" : "chevron.left")
                .font(.system(size: 11, weight: .semibold))
            if let parent = state.parent {
                Text(verbatim: "/" + parent.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text(parent.title).font(.system(size: 12))
                    .foregroundStyle(StudioTheme.textTertiary)
            } else {
                Text(L("ask.command.title")).font(.system(size: 12, weight: .semibold))
            }
            Spacer()
        }
        .foregroundStyle(StudioTheme.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L("ask.command.keys")).lineLimit(1)
            Spacer()
            if let onManage {
                Button(L("ask.command.manage"), action: onManage)
                    .buttonStyle(.plain)
                    .foregroundStyle(AskTheme.accentText)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(StudioTheme.textTertiary)
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

private struct AskCommandRow: View {
    let match: AskCommandMatcher.Match
    var highlighted: Bool

    private var command: AskCommand { match.command }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(highlighted ? AskTheme.accent : StudioTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(highlighted ? AskTheme.accent.opacity(0.16) : AskTheme.hoverFill,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    name
                    if !command.title.isEmpty {
                        Text(command.title).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary).lineLimit(1)
                    }
                    if let badge = command.badge {
                        Text(badge).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioTheme.textTertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                if let detail = command.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing.font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: AskCommandPaletteView.rowHeight)
        .background(highlighted ? AskTheme.accent.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(command.enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isSelected, .isButton] : .isButton)
    }

    /// The name with the typed letters underlined; submenu rows have no slash.
    private var name: some View {
        var text = AttributedString(command.plain ? command.name : "/" + command.name)
        let offset = command.plain ? 0 : 1
        let characters = Array(text.characters.indices)
        for index in match.highlights where index + offset < characters.count {
            let start = characters[index + offset]
            let end = text.characters.index(after: start)
            text[start ..< end].underlineStyle = .single
            text[start ..< end].foregroundColor = AskTheme.accent
        }
        return Text(text)
            .font(.system(size: 13, weight: .semibold, design: command.plain ? .default : .monospaced))
            .foregroundStyle(highlighted ? AskTheme.accentText : StudioTheme.textPrimary)
            .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        if let reason = command.disabledReason {
            Text(reason).lineLimit(1)
        } else if command.selected {
            Image(systemName: "checkmark").foregroundStyle(AskTheme.accent)
        } else {
            switch command.kind {
            case let .toggle(on):
                Text(L(on ? "ask.command.on" : "ask.command.off")).foregroundStyle(on ? AskTheme.accentText : StudioTheme.textTertiary)
            case .submenu:
                HStack(spacing: 4) {
                    if let value = command.trailing { Text(value).lineLimit(1) }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
            case .argument:
                Text((command.trailing ?? "") + " ⇥").lineLimit(1)
            default:
                if let value = command.trailing { AskKeyHint(text: value) }
            }
        }
    }
}
