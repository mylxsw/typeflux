import SwiftUI

/// A keyboard that lights the keys of the shortcut under the pointer, the shortcuts themselves
/// with the set ones first, then, one window at a time, the keys the app fixes and `/` commands.
struct HelpShortcutsPage: View {
    @ObservedObject var model: HelpGuideModel
    @State private var hoveredKeys: [String]?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HelpKeyboardDrawing(lit: HelpKeyboardMap.keyIDs(for: hoveredKeys ?? []))
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 16)
                    cards
                    HelpSectionHeader(title: L("help.shortcuts.windows.title"))
                    HStack(alignment: .top, spacing: 16) {
                        contextList.frame(width: 160)
                        contextContent.frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .onAppear { if let id = model.selectedShortcutID { proxy.scrollTo(id, anchor: .center) } }
            .onChange(of: model.selectedShortcutID) { id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
            ForEach(model.catalog.shortcutCards) { shortcut in
                HelpShortcutCard(shortcut: shortcut, selected: model.selectedShortcutID == shortcut.id) {
                    model.openSettings(.shortcuts)
                } onHover: { hovering in
                    hoveredKeys = hovering ? shortcut.keys : nil
                }
                .id(shortcut.id)
            }
        }
    }

    private var contextList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(HelpShortcutContext.all, id: \.self) { context in
                HelpContextRow(title: context.title, note: note(context), selected: model.shortcutContext == context) {
                    model.shortcutContext = context
                }
            }
        }
    }

    /// When a window's keys apply, for the few where that is not obvious.
    private func note(_ context: HelpShortcutContext) -> String? {
        guard case let .section(section) = context,
              [.result, .recording, .notes, .terminal, .editing].contains(section) else { return nil }
        return L("help.shortcuts.context." + section.rawValue)
    }

    @ViewBuilder private var contextContent: some View {
        switch model.shortcutContext {
        case .commands:
            commands.id("commands")
        case let .section(section):
            HelpBlock {
                let rows = model.catalog.shortcuts(in: section)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, shortcut in
                    HelpRow(symbol: nil, title: shortcut.title, detail: shortcut.detail,
                            selected: model.selectedShortcutID == shortcut.id, showsDivider: index > 0) {
                        HelpKeycaps(keys: shortcut.keys) { model.openSettings(.shortcuts) }
                    }
                    .id(shortcut.id)
                }
            }
        }
    }

    private var commands: some View {
        let rows = model.catalog.commands
        let half = (rows.count + 1) / 2
        return HelpBlock {
            HStack(alignment: .top, spacing: 0) {
                commandColumn(Array(rows.prefix(half)))
                Rectangle().fill(AskTheme.separator).frame(width: 1)
                commandColumn(Array(rows.dropFirst(half)))
            }
        }
    }

    private func commandColumn(_ rows: [HelpCommand]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, command in
                HelpRow(symbol: nil, title: command.title, showsDivider: index > 0) {
                    HelpKeywordLabel(keyword: AskKeyword(keyword: command.name, pluginID: ""), showsAliases: false)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

extension HelpShortcut {
    /// The symbol of the feature a global shortcut starts.
    var symbol: String {
        switch target {
        case .builtIn(.activation), .builtIn(.auxiliary): "mic"
        case .builtIn(.persona): "person.crop.circle"
        case .builtIn(.ask): "magnifyingglass"
        case .builtIn(.history): "doc.on.clipboard"
        case .builtIn(.screenshot): "camera.viewfinder"
        case .action(.openChat): "bubble.left.and.bubble.right"
        case .action(.screenshotText): "text.viewfinder"
        case .action(.translate), .action(.screenshotTranslation): "character.bubble"
        case .action(.openNotes): "note.text"
        case .action(.openWordBook): "book"
        case .action(.openStudio): "gearshape"
        case .action(.openHelp): "questionmark.circle"
        case .action(.ring): "circle.circle"
        default: "keyboard"
        }
    }
}

/// A shortcut and its keys on one line; what it does is its tooltip. Clicking changes it.
struct HelpShortcutCard: View {
    var shortcut: HelpShortcut
    var selected: Bool
    var open: () -> Void
    var onHover: (Bool) -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.rowCorner + 2, style: .continuous)
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: shortcut.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(shortcut.title)
                    .font(.system(size: 13))
                    .foregroundStyle(shortcut.keys == nil ? StudioTheme.textSecondary : StudioTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if shortcut.keys != nil {
                    HelpKeycaps(keys: shortcut.keys)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? AskTheme.accentText : StudioTheme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(shape.fill(selected ? HelpTheme.selection(style)
                    : hovering ? AskTheme.hoverFill : HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            onHover($0)
        }
        .help(shortcut.detail)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(shortcut.keys?.joined(separator: " ") ?? L("help.shortcuts.unset"))
        .accessibilityHint(shortcut.detail)
    }
}

/// A keyboard with the keys of the hovered shortcut lit.
struct HelpKeyboardDrawing: View {
    var lit: Set<String>

    var body: some View {
        VStack(spacing: 3) {
            ForEach(Array(HelpKeyboardMap.rows.enumerated()), id: \.offset) { _, row in
                GeometryReader { proxy in
                    let total = row.map(\.width).reduce(CGFloat(0), +)
                    let unit = (proxy.size.width - CGFloat(row.count - 1) * 3) / total
                    HStack(spacing: 3) {
                        ForEach(row) { key in cap(key).frame(width: unit * key.width) }
                    }
                }
                .frame(height: 20)
            }
        }
        .accessibilityHidden(true)
    }

    private func cap(_ key: HelpKeyboardMap.Key) -> some View {
        let on = lit.contains(key.id)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Text(key.label)
            .font(.system(size: 9))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(on ? Color.white : StudioTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(on ? AskTheme.accent : AskTheme.hoverFill))
            .shadow(color: on ? AskTheme.accent.opacity(0.6) : .clear, radius: 6)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// One window in the shortcuts page's list.
struct HelpContextRow: View {
    var title: String
    var note: String?
    var selected: Bool
    var action: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.rowCorner, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 28)
                .background(shape.fill(selected ? AskTheme.pressFill : hovering ? AskTheme.hoverFill : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(note ?? "")
        .accessibilityLabel(title)
        .accessibilityHint(note ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
