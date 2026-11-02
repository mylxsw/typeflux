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
                        HelpKeywordAnatomy().padding(.bottom, 14)
                        filters
                        ForEach(visibleGroups) { group in
                            let keywords = model.catalog.keywords(in: group)
                            if !keywords.isEmpty {
                                groupTitle(group, count: keywords.count)
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
                .frame(width: 320)
        }
    }

    private var visibleGroups: [HelpKeywordGroup] {
        HelpKeywordGroup.allCases.filter { model.filter == nil || model.filter == $0 }
    }

    private var filters: some View {
        HelpFlowLayout(spacing: 6) {
            HelpFilterChip(title: L("help.group.all"), count: model.catalog.keywords.count,
                           selected: model.filter == nil) { model.setFilter(nil) }
            ForEach(HelpKeywordGroup.allCases) { group in
                let count = model.catalog.keywords(in: group).count
                if count > 0 {
                    HelpFilterChip(title: group.title, count: count, selected: model.filter == group) {
                        model.setFilter(group)
                    }
                }
            }
        }
    }

    private func groupTitle(_ group: HelpKeywordGroup, count: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(group.tint).frame(width: 6, height: 6)
            HelpGroupTitle(title: group.title, count: count,
                           action: group == .mine
                               ? (title: L("help.keywords.manage"), run: { model.openSettings(.keywords) }) : nil)
                .padding(.horizontal, -4)
        }
        .padding(.horizontal, 4)
    }

    private func row(_ keyword: HelpKeyword, first: Bool) -> some View {
        HelpKeywordRow(keyword: keyword, selected: model.selectedKeywordID == keyword.id, showsDivider: !first) {
            model.selectedKeywordID = keyword.id
        }
    }
}

/// How a keyword is typed, drawn on its parts: the one thing to know before the list.
struct HelpKeywordAnatomy: View {
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.help.blockCorner, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HelpFlowLayout(spacing: 8) {
                part("help.keywords.anatomy.keyword") {
                    HelpKeywordLabel(keyword: AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id),
                                     showsAliases: false)
                }
                part("help.keywords.anatomy.space") {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(AskTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 28, height: 20)
                        .overlay(Text("␣").font(.system(size: 10)).foregroundStyle(StudioTheme.textTertiary))
                }
                part("help.keywords.anatomy.content") {
                    Text(L("help.keyword.example.translate")).font(.system(size: 13))
                }
                part("help.keywords.anatomy.run") { HelpKeycap(key: "↩") }
                part("help.keywords.anatomy.result") {
                    HStack(spacing: 8) {
                        Text("→").foregroundStyle(StudioTheme.textTertiary)
                        Text(L("help.keywords.anatomy.sample")).font(.system(size: 13, weight: .semibold))
                    }
                }
            }
            Rectangle().fill(AskTheme.separator).frame(height: 1)
            Text(L("help.keywords.anatomy.note"))
                .font(.system(size: 12))
                .foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [HelpCoreAction.launcher.tint.opacity(0.14), .clear],
                                   startPoint: .leading, endPoint: .trailing).clipShape(shape))
        .background(shape.fill(HelpTheme.blockFill(style)))
        .overlay(shape.strokeBorder(HelpTheme.blockBorder(style)))
        .accessibilityElement(children: .combine)
    }

    private func part(_ key: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 5) {
            content().frame(height: 22)
            Text(L(key)).font(.system(size: 10.5)).foregroundStyle(StudioTheme.textTertiary).lineLimit(1)
        }
        .fixedSize()
    }
}

/// One keyword in the list: what to type first, since that is what people come here for.
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(keyword.title).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                Text(keyword.statusText ?? keyword.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(keyword.statusText == nil ? StudioTheme.textTertiary : StudioTheme.warning)
                    .lineLimit(1)
            }
            .opacity(keyword.isAvailable ? 1 : 0.5)
            Spacer(minLength: 4)
            if let shortcut = keyword.shortcut { HelpKeycaps(keys: shortcut) }
            if keyword.usesSelection { HelpPill(text: L("help.keyword.selection.badge")) }
            if keyword.usageCount > 0 {
                Text(L("help.keyword.used.short", keyword.usageCount))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary).fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(selected ? HelpTheme.selection(style) : hovering ? AskTheme.hoverFill : .clear)
        .overlay(alignment: .top) {
            if showsDivider, !selected { Rectangle().fill(AskTheme.separator).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyword.title)
        .accessibilityValue(keyword.keyword.keyword)
        .accessibilityHint(keyword.statusText ?? keyword.detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
    }
}

/// A small label beside a row.
struct HelpPill: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(StudioTheme.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(AskTheme.hoverFill))
    }
}

/// Typing the keyword's first example over and over, in a small launcher.
struct HelpKeywordDemo: View {
    var keyword: HelpKeyword

    var body: some View {
        let argument = HelpKeywordDetail.exampleArgument(keyword) ?? ""
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
        .accessibilityHidden(true)
    }
}

/// What the selected keyword does, how to type it, its keys and where it comes from.
struct HelpKeywordDetail: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        if let keyword = model.selectedKeyword {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            HelpSymbolTile(symbol: keyword.symbol, tint: keyword.group.tint, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(keyword.title).font(.system(size: 17, weight: .semibold))
                                Text(keyword.origin + " · " + keyword.group.title)
                                    .font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
                            }
                        }
                        .padding(.bottom, 12)
                        HelpFlowLayout(spacing: 5) {
                            ForEach(keyword.keyword.allKeywords, id: \.self) { word in
                                HelpKeywordLabel(keyword: AskKeyword(keyword: word,
                                                                     pluginID: keyword.keyword.pluginID),
                                                 showsAliases: false)
                            }
                        }
                        .padding(.bottom, 12)
                        if !keyword.detail.isEmpty {
                            Text(keyword.detail).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let status = keyword.statusText {
                            Text(status).font(.system(size: 12)).foregroundStyle(StudioTheme.warning).padding(.top, 6)
                        }
                        HelpKeywordDemo(keyword: keyword).padding(.top, 14)
                        section(L("help.keyword.howto"))
                        ForEach(Array(Self.howTo(keyword).enumerated()), id: \.offset) { index, step in
                            howToRow(index + 1, step)
                        }
                        section(L("help.keyword.examples"))
                        ForEach(Self.examples(keyword), id: \.self) { example in
                            exampleRow(keyword, example)
                        }
                        section(L("help.keyword.shortcut"))
                        HStack(spacing: 8) {
                            Text(L(keyword.shortcut == nil
                                    ? "help.keyword.shortcut.none" : "help.keyword.shortcut.set"))
                                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            HelpKeycaps(keys: keyword.shortcut) { model.openSettings(.shortcuts) }
                        }
                        section(L("help.keyword.usage"))
                        HStack {
                            Text(keyword.usageCount > 0
                                ? L("help.keyword.used", keyword.usageCount) : L("help.keyword.unused"))
                            Spacer(minLength: 0)
                            Text(keyword.origin).foregroundStyle(StudioTheme.textTertiary)
                        }
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.textSecondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
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
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(AskTheme.separator).frame(height: 1) }
            }
        } else {
            Text(L("help.keyword.none")).font(.system(size: 13)).foregroundStyle(StudioTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            .padding(.top, 18).padding(.bottom, 8)
    }

    /// What to type: the keyword with a sample after it when it takes text, and the keyword
    /// alone when it works on the selection or needs nothing.
    static func examples(_ keyword: HelpKeyword) -> [String] {
        let word = keyword.keyword.keyword
        guard let argument = exampleArgument(keyword) else { return [word] }
        return [word + " " + argument] + (keyword.usesSelection ? [word] : [])
    }

    /// How to use the keyword, one step a line: typing after it, or just running it, and working
    /// on the selection when it can.
    static func howTo(_ keyword: HelpKeyword) -> [String] {
        let word = keyword.keyword.keyword
        var steps = [L(exampleArgument(keyword) == nil ? "help.keyword.howto.run" : "help.keyword.howto.typed", word)]
        if keyword.usesSelection { steps.append(L("help.keyword.howto.selection", word)) }
        steps.append(L("help.keyword.howto.complete"))
        return steps
    }

    /// What pressing Return on an example does.
    static func exampleHint(_ keyword: HelpKeyword, typed: Bool) -> String {
        if typed { return "help.keyword.example.typed" }
        return keyword.usesSelection ? "help.keyword.example.selection" : "help.keyword.example.run"
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

    private func howToRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(AskTheme.hoverFill))
            Text(text).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 8)
    }

    private func exampleRow(_ keyword: HelpKeyword, _ example: String) -> some View {
        let word = keyword.keyword.keyword
        let argument = example == word ? "" : String(example.dropFirst(word.count + 1))
        return Button { model.tryKeyword(keyword, argument: argument) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(example).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(StudioTheme.textPrimary)
                Text(L(Self.exampleHint(keyword, typed: !argument.isEmpty)))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AskTheme.hoverFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!keyword.isAvailable)
        .padding(.bottom, 6)
    }
}
