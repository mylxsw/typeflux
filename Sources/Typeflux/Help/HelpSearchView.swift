import SwiftUI

/// Results across keywords, shortcuts, commands and questions, or a way to ask the AI.
struct HelpSearchView: View {
    @ObservedObject var model: HelpGuideModel

    var body: some View {
        let items = model.searchItems
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(StudioTheme.textTertiary)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AskTheme.hoverFill))
                    .padding(.bottom, 10)
                    .accessibilityHidden(true)
                Text(L("help.search.empty", model.query.trimmingCharacters(in: .whitespaces)))
                    .font(.system(size: 15)).foregroundStyle(StudioTheme.textPrimary)
                HelpButton(title: L("help.search.askAI"), symbol: "sparkles", trailing: "⌘↩", prominent: true) {
                    model.askAI()
                }
                .padding(.top, 14)
            }
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        let groups = grouped(items)
                        ForEach(groups, id: \.title) { group in
                            HelpGroupTitle(title: group.title)
                            HelpBlock {
                                ForEach(group.items, id: \.offset) { entry in
                                    row(entry.element, index: entry.offset,
                                        first: entry.offset == group.items.first?.offset)
                                        .id(entry.offset)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .onChange(of: model.searchFocus) { focus in proxy.scrollTo(focus) }
            }
        }
    }

    private struct Group {
        var title: String
        var items: [(offset: Int, element: HelpGuideModel.SearchItem)]
    }

    /// Splits the flat result list into its groups, keeping each item's index for the highlight.
    private func grouped(_ items: [HelpGuideModel.SearchItem]) -> [Group] {
        var groups: [Group] = []
        for (offset, item) in items.enumerated() {
            let title = switch item {
            case .keyword: L("help.page.keywords")
            case let .shortcut(shortcut):
                HelpShortcutContext(shortcut.section) == nil
                    ? L("help.search.group.global") : L("help.search.group.window")
            case .command: L("help.shortcuts.commands.short")
            case .question: L("help.page.faq")
            }
            if groups.last?.title == title {
                groups[groups.count - 1].items.append((offset, item))
            } else {
                groups.append(Group(title: title, items: [(offset, item)]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func row(_ item: HelpGuideModel.SearchItem, index: Int, first: Bool) -> some View {
        let selected = model.searchFocus == index
        let open = { model.searchFocus = index; model.open(item) }
        let query = model.query
        switch item {
        case let .keyword(keyword):
            HelpRow(symbol: keyword.symbol, title: keyword.title, detail: keyword.detail, selected: selected,
                    dimmed: !keyword.isAvailable, showsDivider: !first, highlight: query, action: open) {
                HelpKeywordLabel(keyword: keyword.keyword, maxAliases: 2)
            }
        case let .shortcut(shortcut):
            HelpRow(symbol: "keyboard", title: shortcut.title, detail: shortcut.section.title, selected: selected,
                    showsDivider: !first, highlight: query, action: open) {
                HelpKeycaps(keys: shortcut.keys)
            }
        case let .command(command):
            HelpRow(symbol: "slash.circle", title: command.title, selected: selected, showsDivider: !first,
                    highlight: query, action: open) {
                HelpKeywordLabel(keyword: AskKeyword(keyword: command.name, pluginID: ""), showsAliases: false)
            }
        case let .question(question):
            HelpRow(symbol: "questionmark.circle", title: question.question, selected: selected,
                    showsDivider: !first, highlight: query, action: open) { EmptyView() }
        }
    }
}
