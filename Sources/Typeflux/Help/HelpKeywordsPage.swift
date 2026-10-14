import SwiftUI

/// Every keyword the launcher knows right now, grouped by use, with a detail pane for the
/// selected one. ↑↓ move the selection and Return tries the keyword in the launcher.
struct HelpKeywordsPage: View {
    @ObservedObject var model: HelpGuideModel
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        filters
                        ForEach(visibleGroups) { group in
                            let keywords = model.catalog.keywords(in: group)
                            if !keywords.isEmpty {
                                HelpGroupTitle(
                                    title: group.title, count: keywords.count,
                                    action: group == .mine ? manageAction : nil
                                )
                                HelpBlock {
                                    ForEach(Array(keywords.enumerated()), id: \.element.id) { index, keyword in
                                        row(keyword, first: index == 0).id(keyword.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
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
                .frame(width: 340)
        }
    }

    private var visibleGroups: [HelpKeywordGroup] {
        HelpKeywordGroup.allCases.filter { model.filter == nil || model.filter == $0 }
    }

    private var manageAction: (title: String, run: () -> Void) {
        (title: L("help.keywords.manage"), run: { model.openSettings(.keywords) })
    }

    private var filters: some View {
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 9 : 7, style: .continuous)
        return HStack(spacing: 2) {
            segment(nil, L("help.group.all"))
            ForEach(HelpKeywordGroup.allCases) { group in
                if !model.catalog.keywords(in: group).isEmpty { segment(group, group.title) }
            }
        }
        .padding(2)
        .background(shape.fill(style.usesGlass ? AskTheme.hoverFill : AskTheme.segmentTrack))
        .padding(.top, 2)
    }

    private func segment(_ group: HelpKeywordGroup?, _ title: String) -> some View {
        let selected = model.filter == group
        let shape = RoundedRectangle(cornerRadius: style.usesGlass ? 7 : 5, style: .continuous)
        return Button { model.setFilter(group) } label: {
            Text(title).font(.system(size: 12.5))
                .foregroundStyle(selected ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(shape.fill(selected ? AskTheme.popoverSurface : .clear)
                    .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 1, y: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ keyword: HelpKeyword, first: Bool) -> some View {
        let detail = [keyword.statusText, keyword.detail].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        let select = { model.selectedKeywordID = keyword.id }
        return HelpRow(symbol: keyword.symbol, title: keyword.title, detail: detail,
                       selected: model.selectedKeywordID == keyword.id, dimmed: !keyword.isAvailable,
                       showsDivider: !first, action: select) {
            HStack(spacing: 8) {
                if let shortcut = keyword.shortcut { HelpKeycaps(keys: shortcut) }
                HelpKeywordLabel(keyword: keyword.keyword, maxAliases: 2)
            }
        }
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
                            Image(systemName: keyword.symbol).font(.system(size: 18))
                                .foregroundStyle(StudioTheme.textSecondary)
                                .frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AskTheme.launcherKeyword))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(keyword.title).font(.system(size: 16, weight: .semibold))
                                HStack(spacing: 5) {
                                    ForEach(keyword.keyword.allKeywords, id: \.self) { word in
                                        HelpKeywordLabel(keyword: AskKeyword(keyword: word,
                                                                             pluginID: keyword.keyword.pluginID),
                                                         showsAliases: false)
                                    }
                                }
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
                        if keyword.usesSelection {
                            Text(L("help.keyword.selection")).font(.system(size: 12))
                                .foregroundStyle(StudioTheme.textTertiary).padding(.top, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        section(L("help.keyword.examples"))
                        ForEach(Self.examples(keyword), id: \.self) { example in
                            exampleRow(keyword, example)
                        }
                        section(L("help.keyword.shortcut"))
                        HStack {
                            Text(L(keyword.shortcut == nil
                                    ? "help.keyword.shortcut.none" : "help.keyword.shortcut.set"))
                                .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
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

    /// What pressing Return on an example does.
    static func exampleHint(_ keyword: HelpKeyword, typed: Bool) -> String {
        if typed { return "help.keyword.example.typed" }
        return keyword.usesSelection ? "help.keyword.example.selection" : "help.keyword.example.run"
    }

    static func exampleArgument(_ keyword: HelpKeyword) -> String? {
        let kind: String? = switch keyword.keyword.pluginID {
        case AskTranslatePlugin.id: AskTranslatePlugin.opensWordBook(keyword.keyword.options) ? "word" : "translate"
        case AskPromptPlugin.id: "text"
        case AskWebSearchPlugin.id, AskFileSearchPlugin.id, AskBrowserSearchPlugin.tabsID,
             AskBrowserSearchPlugin.bookmarksID, AskNotesPlugin.id, AskHistoryPlugin.id, AskClipboardPlugin.id:
            "search"
        case AskEmojiPlugin.id: "emoji"
        case AskKillAppPlugin.id: "app"
        default: nil
        }
        return kind.map { L("help.keyword.example.\($0)") }
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
