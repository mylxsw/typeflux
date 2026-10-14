import SwiftUI

/// Every shortcut with the keys the user set: Typeflux's global ones (an unset one leads to
/// the Shortcuts settings), keyword shortcuts, the fixed keys and the `/` commands.
struct HelpShortcutsPage: View {
    @ObservedObject var model: HelpOverlayModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        section(.global, action: (L("help.shortcuts.edit"), { model.openSettings(.shortcuts) }))
                        section(.keyword, action: (L("help.shortcuts.add"), { model.openSettings(.shortcuts) }),
                                emptyText: L("help.shortcuts.keyword.empty"))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        section(.launcher)
                        section(.result)
                    }
                }
                section(.chat)
                HelpGroupTitle(title: L("help.shortcuts.commands"))
                commands
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func section(_ section: HelpShortcutSection, action: (String, () -> Void)? = nil,
                         emptyText: String? = nil) -> some View {
        let rows = model.catalog.shortcuts(in: section)
        HelpGroupTitle(title: section.title, action: action.map { (title: $0.0, run: $0.1) })
        if rows.isEmpty, let emptyText {
            HelpBlock {
                HelpRow(symbol: nil, title: emptyText, showsDivider: false) { EmptyView() }
            }
        } else {
            HelpBlock {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, shortcut in
                    HelpRow(symbol: nil, title: shortcut.title, detail: shortcut.detail, showsDivider: index > 0) {
                        HelpKeycaps(keys: shortcut.keys) { model.openSettings(.shortcuts) }
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

/// Permission checks first, then the questions; ones a missing permission explains come first.
struct HelpQuestionsPage: View {
    @ObservedObject var model: HelpOverlayModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HelpGroupTitle(title: L("help.faq.status"))
                    HelpBlock {
                        ForEach(Array(model.permissions.enumerated()), id: \.element.id) { index, permission in
                            // What is missing goes on the second line; the trailing label stays short.
                            HelpRow(symbol: nil, title: permission.title,
                                    detail: permission.granted ? "" : permission.detail, showsDivider: index > 0) {
                                HStack(spacing: 10) {
                                    Circle().fill(permission.granted ? StudioTheme.success : StudioTheme.warning)
                                        .frame(width: 7, height: 7)
                                    Text(L(permission.granted ? "help.faq.granted" : "help.faq.notGranted"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(permission.granted
                                            ? StudioTheme.textTertiary : StudioTheme.warning)
                                    if !permission.granted {
                                        HelpButton(title: L("help.faq.fix")) { model.fix(permission.id) }
                                    }
                                }
                            }
                        }
                    }
                    HelpGroupTitle(title: L("help.faq.questions"))
                    HelpBlock {
                        ForEach(Array(orderedQuestions.enumerated()), id: \.element.id) { index, question in
                            questionRow(question, first: index == 0).id(question.id)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
            .onAppear { if let id = model.openQuestionID { proxy.scrollTo(id) } }
        }
    }

    private var orderedQuestions: [HelpQuestion] {
        let relevant = model.relevantQuestions
        return relevant + model.catalog.questions.filter { !relevant.contains($0) }
    }

    private func questionRow(_ question: HelpQuestion, first: Bool) -> some View {
        let open = model.openQuestionID == question.id
        return VStack(alignment: .leading, spacing: 0) {
            HelpRow(symbol: "questionmark.circle", title: question.question, showsDivider: !first,
                    action: { withAnimation(.easeOut(duration: 0.15)) { model.toggleQuestion(question.id) } }) {
                HStack(spacing: 8) {
                    if model.isRelevant(question) {
                        Text(L("help.faq.relevant")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            if open {
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.answer).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let destination = question.destination {
                        HelpButton(title: L("help.faq.openSettings")) { model.openSettings(destination) }
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
            }
        }
    }
}

/// Results across keywords, shortcuts, commands and questions, or a way to ask the AI.
struct HelpSearchView: View {
    @ObservedObject var model: HelpOverlayModel

    var body: some View {
        let items = model.searchItems
        if items.isEmpty {
            VStack(spacing: 6) {
                Text(L("help.search.empty", model.query.trimmingCharacters(in: .whitespaces)))
                    .font(.system(size: 15)).foregroundStyle(StudioTheme.textPrimary)
                Text(L("help.search.empty.detail")).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
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
                            HelpGroupTitle(title: group.title, count: group.items.count)
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
        var items: [(offset: Int, element: HelpOverlayModel.SearchItem)]
    }

    /// Splits the flat result list into its groups, keeping each item's index for the highlight.
    private func grouped(_ items: [HelpOverlayModel.SearchItem]) -> [Group] {
        var groups: [Group] = []
        for (offset, item) in items.enumerated() {
            let title = switch item {
            case .keyword: L("help.page.keywords")
            case .shortcut: L("help.page.shortcuts")
            case .command: L("help.shortcuts.commands")
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
    private func row(_ item: HelpOverlayModel.SearchItem, index: Int, first: Bool) -> some View {
        let selected = model.searchFocus == index
        let open = { model.searchFocus = index; model.open(item) }
        switch item {
        case let .keyword(keyword):
            HelpRow(symbol: keyword.symbol, title: keyword.title, detail: keyword.detail, selected: selected,
                    dimmed: !keyword.isAvailable, showsDivider: !first, action: open) {
                HelpKeywordLabel(keyword: keyword.keyword, maxAliases: 2)
            }
        case let .shortcut(shortcut):
            HelpRow(symbol: "keyboard", title: shortcut.title, detail: shortcut.section.title, selected: selected,
                    showsDivider: !first, action: open) {
                HelpKeycaps(keys: shortcut.keys)
            }
        case let .command(command):
            HelpRow(symbol: "slash.circle", title: command.title, selected: selected, showsDivider: !first,
                    action: open) {
                HelpKeywordLabel(keyword: AskKeyword(keyword: command.name, pluginID: ""), showsAliases: false)
            }
        case let .question(question):
            HelpRow(symbol: "questionmark.circle", title: question.question, selected: selected,
                    showsDivider: !first, action: open) { EmptyView() }
        }
    }
}
