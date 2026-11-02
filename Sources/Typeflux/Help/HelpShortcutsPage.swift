import SwiftUI

/// The global shortcuts first, with the keys the user set drawn on a keyboard; then keyword
/// shortcuts; then, one window at a time, the keys the app fixes and the `/` commands.
struct HelpShortcutsPage: View {
    @ObservedObject var model: HelpGuideModel
    @State private var hoveredKeys: [String]?
    @State private var hoveredTint: Color = AskTheme.accent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    cards(model.catalog.shortcuts(in: .global))
                    keywordShortcuts
                    HelpSectionHeader(title: L("help.shortcuts.windows.title"),
                                      detail: L("help.shortcuts.windows.detail"))
                    HStack(alignment: .top, spacing: 16) {
                        contextList.frame(width: 172)
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

    private var hero: some View {
        let text = VStack(alignment: .leading, spacing: 6) {
            Text(L("help.shortcuts.hero.eyebrow"))
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(AskTheme.accentText)
            Text(L("help.shortcuts.hero.title")).font(.studioDisplay(22, weight: .bold))
            Text(L("help.shortcuts.hero.detail"))
                .font(.system(size: 12.5))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                text.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                HelpKeyboardDrawing(lit: HelpKeyboardMap.keyIDs(for: hoveredKeys ?? []), tint: hoveredTint)
                    .frame(width: 340)
            }
            text.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 14)
    }

    private func cards(_ shortcuts: [HelpShortcut]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 186), spacing: 10)], spacing: 10) {
            ForEach(shortcuts) { shortcut in
                HelpShortcutCard(shortcut: shortcut, selected: model.selectedShortcutID == shortcut.id) {
                    model.openSettings(.shortcuts)
                } onHover: { hovering in
                    hoveredKeys = hovering ? shortcut.keys : nil
                    if hovering { hoveredTint = shortcut.tint }
                }
                .id(shortcut.id)
            }
        }
    }

    @ViewBuilder private var keywordShortcuts: some View {
        let rows = model.catalog.shortcuts(in: .keyword)
        HelpGroupTitle(title: HelpShortcutSection.keyword.title,
                       action: (title: L("help.shortcuts.add"), run: { model.openSettings(.shortcuts) }))
        if rows.isEmpty {
            HelpBlock {
                HelpRow(symbol: nil, title: L("help.shortcuts.keyword.empty"), showsDivider: false) { EmptyView() }
            }
        } else {
            cards(rows)
        }
    }

    private var contextList: some View {
        VStack(alignment: .leading, spacing: 1) {
            contextGroup(L("help.shortcuts.group.conversation"), HelpShortcutContext.conversation)
            contextGroup(L("help.shortcuts.group.tools"), HelpShortcutContext.tools).padding(.top, 10)
        }
    }

    private func contextGroup(_ title: String, _ contexts: [HelpShortcutContext]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(StudioTheme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(contexts, id: \.self) { context in
                HelpContextRow(title: context.title, count: count(context),
                               selected: model.shortcutContext == context) {
                    model.shortcutContext = context
                }
            }
        }
    }

    private func count(_ context: HelpShortcutContext) -> Int {
        switch context {
        case let .section(section): model.catalog.shortcuts(in: section).count
        case .commands: model.catalog.commands.count
        }
    }

    @ViewBuilder private var contextContent: some View {
        switch model.shortcutContext {
        case .commands:
            VStack(alignment: .leading, spacing: 0) {
                HelpGroupTitle(title: L("help.shortcuts.commands")).id("commands")
                commands
            }
        case let .section(section):
            VStack(alignment: .leading, spacing: 8) {
                if [.result, .recording, .notes, .terminal, .editing].contains(section) {
                    Text(L("help.shortcuts.context." + section.rawValue))
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
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
    /// The symbol and color of the feature a global shortcut starts.
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

    var tint: Color {
        switch target {
        case .builtIn(.activation), .builtIn(.auxiliary), .builtIn(.persona): HelpCoreAction.voice.tint
        case .builtIn(.ask), .action(.translate), .action(.screenshotTranslation): HelpCoreAction.launcher.tint
        case .action(.ring): HelpCoreAction.ring.tint
        case .action(.openChat), .builtIn(.screenshot), .action(.screenshotText): HelpCoreAction.chat.tint
        case .builtIn(.history), .action(.openNotes), .action(.openWordBook):
            OnboardingWelcomeHero.Scene.tools.tint
        default: AskTheme.accent
        }
    }
}

/// A shortcut with its keys large enough to read at a glance; an unset one offers to set them.
struct HelpShortcutCard: View {
    var shortcut: HelpShortcut
    var selected: Bool
    var open: () -> Void
    var onHover: (Bool) -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HelpSymbolTile(symbol: shortcut.symbol, tint: shortcut.tint)
                    Text(shortcut.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if hovering, shortcut.keys != nil {
                        Text(L("help.shortcuts.edit")).font(.system(size: 11.5)).foregroundStyle(AskTheme.accentText)
                    }
                }
                Text(shortcut.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                if shortcut.keys != nil {
                    HelpKeycaps(keys: shortcut.keys, large: true)
                } else {
                    Label(L("help.shortcuts.setUp"), systemImage: "plus")
                        .font(.system(size: 12))
                        .foregroundStyle(AskTheme.accentText)
                        .frame(height: 28)
                }
            }
            .padding(13)
            .background(shape.fill(selected ? HelpTheme.selection(style) : HelpTheme.blockFill(style)))
            .overlay(shape.strokeBorder(hovering ? shortcut.tint.opacity(0.5) : HelpTheme.blockBorder(style)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            onHover($0)
        }
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(shortcut.keys?.joined(separator: " ") ?? L("help.shortcuts.unset"))
        .accessibilityHint(shortcut.detail)
    }
}

/// A keyboard with the keys of the hovered shortcut lit.
struct HelpKeyboardDrawing: View {
    var lit: Set<String>
    var tint: Color
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
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
        .padding(10)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
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
            .background(shape.fill(on ? tint : AskTheme.hoverFill))
            .shadow(color: on ? tint.opacity(0.6) : .clear, radius: 6)
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// One window in the shortcuts page's list.
struct HelpContextRow: View {
    var title: String
    var count: Int
    var selected: Bool
    var action: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.rowCorner, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(shape.fill(selected ? HelpTheme.selection(style) : hovering ? AskTheme.hoverFill : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
