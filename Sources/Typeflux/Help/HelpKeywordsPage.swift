import SwiftUI

/// Every keyword the launcher knows right now, grouped by use, with a detail pane for the
/// selected one. ↑↓ move the selection and Return tries the keyword in the launcher.
struct HelpKeywordsPage: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HelpKeywordAnatomy().padding(.bottom, 12)
                        filters
                        ForEach(visibleGroups) { group in
                            let keywords = model.catalog.keywords(in: group)
                            if !keywords.isEmpty {
                                HelpGroupTitle(title: group.title,
                                               action: group == .mine
                                                   ? (title: L("help.keywords.manage"), run: { model.openSettings(.keywords) })
                                                   : nil)
                                HelpBlock {
                                    ForEach(Array(keywords.enumerated()), id: \.element.id) { index, keyword in
                                        row(keyword, first: index == 0).id(keyword.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .onChange(of: model.selectedKeywordID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
                .onAppear { if let id = model.selectedKeywordID { proxy.scrollTo(id, anchor: .center) } }
            }
            Rectangle().fill(AskTheme.separator).frame(width: 1)
            HelpKeywordDetail(model: model)
                .frame(width: 300)
        }
    }

    private var visibleGroups: [HelpKeywordGroup] {
        HelpKeywordGroup.allCases.filter { model.filter == nil || model.filter == $0 }
    }

    private var filters: some View {
        HelpFlowLayout(spacing: 4) {
            HelpFilterChip(title: L("help.group.all"), selected: model.filter == nil) { model.setFilter(nil) }
            ForEach(HelpKeywordGroup.allCases) { group in
                if !model.catalog.keywords(in: group).isEmpty {
                    HelpFilterChip(title: group.title, selected: model.filter == group) { model.setFilter(group) }
                }
            }
        }
    }

    private func row(_ keyword: HelpKeyword, first: Bool) -> some View {
        HelpKeywordRow(keyword: keyword, selected: model.selectedKeywordID == keyword.id, showsDivider: !first) {
            model.selectedKeywordID = keyword.id
        }
    }
}

/// How a keyword is typed, drawn rather than described.
struct HelpKeywordAnatomy: View {
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        HStack(spacing: 8) {
            HelpKeywordLabel(keyword: AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id), showsAliases: false)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(AskTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: 26, height: 18)
                .overlay(Text("␣").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary))
            Text(L("help.keyword.example.translate")).font(.system(size: 13))
            HelpKeycap(key: "↩")
            Text("→").foregroundStyle(StudioTheme.textTertiary)
            Text(L("help.keywords.anatomy.sample")).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
        .help(L("help.keywords.anatomy.note"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("help.keywords.anatomy.note"))
    }
}

/// One keyword in the list: what to type and its name. The rest is in the detail pane.
struct HelpKeywordRow: View {
    var keyword: HelpKeyword
    var selected: Bool
    var showsDivider: Bool
    var select: () -> Void
    @Environment(\.interfaceStyle) private var style
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false)
                .frame(width: 72, alignment: .leading)
            Text(keyword.title).font(.system(size: 13)).lineLimit(1)
                .opacity(keyword.isAvailable ? 1 : 0.5)
            Spacer(minLength: 4)
            if let status = keyword.statusText {
                Text(status).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
            }
            if let shortcut = keyword.shortcut { HelpKeycaps(keys: shortcut) }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(selected ? HelpTheme.selection(style) : hovering ? AskTheme.hoverFill : .clear)
        .overlay(alignment: .top) {
            if showsDivider, !selected { Rectangle().fill(AskTheme.separator).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .help(keyword.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyword.title)
        .accessibilityValue(keyword.keyword.keyword)
        .accessibilityHint(keyword.statusText ?? keyword.detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }
}

/// Typing the keyword's first example over and over in a small launcher. Clicking tries it.
struct HelpKeywordDemo: View {
    @ObservedObject var model: HelpGuideModel
    var keyword: HelpKeyword

    var body: some View {
        let argument = HelpKeywordDetail.exampleArgument(keyword) ?? ""
        Button { model.tryKeyword(keyword, argument: argument) } label: {
            HelpLoop(period: 4.5, stillPhase: 0.9) { phase in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).opacity(0.5)
                        HelpKeywordLabel(keyword: keyword.keyword, showsAliases: false)
                        Text(HelpSceneTimeline.revealed(argument, phase: phase, end: 0.5))
                            .font(.system(size: 13))
                            .lineLimit(1)
                        HelpCaret(phase: (phase * 4).truncatingRemainder(dividingBy: 1))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    Rectangle().fill(AskTheme.separator).frame(height: 1)
                    HStack(spacing: 8) {
                        Image(systemName: keyword.symbol).font(.system(size: 12))
                        Text(keyword.title).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("↩").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AskTheme.hoverFill))
                    .padding(5)
                    .opacity(phase > 0.55 ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: phase > 0.55)
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AskTheme.popoverSurface))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AskTheme.border))
                .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
            }
            .id(keyword.id)
        }
        .buttonStyle(.plain)
        .disabled(!keyword.isAvailable)
        .help(HelpKeywordDetail.examples(keyword).first ?? keyword.keyword.keyword)
        .accessibilityLabel(HelpKeywordDetail.examples(keyword).first ?? keyword.keyword.keyword)
    }
}

/// The selected keyword: its name and spellings, what it does, its demo and its key.
struct HelpKeywordDetail: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        if let keyword = model.selectedKeyword {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text(keyword.title).font(.system(size: 17, weight: .semibold))
                            if keyword.usesSelection {
                                Image(systemName: "text.cursor")
                                    .font(.system(size: 12))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .help(L("help.keywords.anatomy.note"))
                                    .accessibilityLabel(L("help.keywords.anatomy.note"))
                            }
                        }
                        HelpFlowLayout(spacing: 5) {
                            ForEach(keyword.keyword.allKeywords, id: \.self) { word in
                                HelpKeywordLabel(keyword: AskKeyword(keyword: word,
                                                                     pluginID: keyword.keyword.pluginID),
                                                 showsAliases: false)
                            }
                        }
                        if !keyword.detail.isEmpty {
                            Text(keyword.detail).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let status = keyword.statusText {
                            Text(status).font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
                        }
                        HelpKeywordDemo(model: model, keyword: keyword).padding(.top, 4)
                        HStack(spacing: 8) {
                            Text(L("help.keyword.shortcut")).font(.system(size: 12.5))
                                .foregroundStyle(StudioTheme.textSecondary)
                            Spacer(minLength: 0)
                            HelpKeycaps(keys: keyword.shortcut) { model.openSettings(.shortcuts) }
                        }
                        .padding(.top, 4)
                        .help(L(keyword.shortcut == nil ? "help.keyword.shortcut.none" : "help.keyword.shortcut.set"))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                HStack(spacing: 8) {
                    HelpButton(title: L("help.keyword.edit")) {
                        model.openSettings(keyword.isWorkflow ? .workflows : .keywords)
                    }
                    Spacer(minLength: 0)
                    HelpButton(title: L("help.keyword.try"), trailing: "↩", prominent: true) {
                        model.tryKeyword(keyword)
                    }
                    .disabled(!keyword.isAvailable)
                    .opacity(keyword.isAvailable ? 1 : 0.5)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        } else {
            Text(L("help.keyword.none")).font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What to type: the keyword with a sample after it when it takes text, and the keyword
    /// alone when it works on the selection or needs nothing.
    static func examples(_ keyword: HelpKeyword) -> [String] {
        let word = keyword.keyword.keyword
        guard let argument = exampleArgument(keyword) else { return [word] }
        return [word + " " + argument] + (keyword.usesSelection ? [word] : [])
    }

    static func exampleArgument(_ keyword: HelpKeyword) -> String? {
        if keyword.keyword.pluginID == AskTerminalCommandPlugin.id { return "pwd" }
        let kind: String? = switch keyword.keyword.pluginID {
        case AskTranslatePlugin.id: AskTranslatePlugin.opensWordBook(keyword.keyword.options) ? "word" : "translate"
        case AskPromptPlugin.id: "text"
        case AskWebSearchPlugin.id, AskFileSearchPlugin.id, AskSemanticFileSearchPlugin.id,
             AskBrowserSearchPlugin.tabsID,
             AskBrowserSearchPlugin.bookmarksID, AskNotesPlugin.id, AskHistoryPlugin.id, AskClipboardPlugin.id:
            "search"
        case AskEmojiPlugin.id: "emoji"
        case AskKillAppPlugin.id: "app"
        case AskWorldClockPlugin.id: "city"
        default: nil
        }
        return kind.map { L("help.keyword.example.\($0)") }
    }
}
