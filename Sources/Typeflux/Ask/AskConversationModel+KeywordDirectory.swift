import Foundation

extension AskConversationModel {
    func launcherSearchEntries(language: AppLanguage) -> [AskLauncherSearchEntry] {
        var entries = launcherKeywordDirectory(language: language).filter(\.canEnter).map {
            AskLauncherSearchEntry(keyword: $0.keyword, title: $0.title, detail: $0.detail, symbol: $0.symbol,
                                   command: AskSystemCommand(pluginID: $0.keyword.pluginID),
                                   alternateNames: [$0.keyword.options[AskWorkflowPlugin.titleOption]].compactMap { $0 })
        }
        for command in AskSystemCommand.allCases where !entries.contains(where: { $0.command == command }) {
            entries.append(.init(keyword: .init(keyword: "", pluginID: command.id), title: command.title,
                                 detail: L("ask.system.title"), symbol: command.symbol, command: command))
        }
        return entries
    }

    /// Searching discovers a feature; entering it never executes an on-submit workflow.
    func enterLauncherSearchEntry(_ entry: AskLauncherSearchEntry) {
        guard let current = launcherSearchEntries(language: AppLocalization.shared.language).first(where: { $0.id == entry.id })
        else { return }
        let listsAtOnce = [AskPrefixPlugin.id, AskHistoryPlugin.id, AskNotesPlugin.id, AskBrowserSearchPlugin.tabsID, AskBrowserSearchPlugin.bookmarksID]
        plugins.enter(current.keyword, waitingForInput: !listsAtOnce.contains(current.keyword.pluginID))
        launcherDraft.text = ""
        plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language)
    }

    /// Enters the directory even when Return precedes the view's keyword hint update.
    @discardableResult
    func enterKeywordDirectoryFromLauncher() -> Bool {
        enterLauncherKeywordFromText(pluginID: AskPrefixPlugin.id)
    }

    @discardableResult
    func enterLauncherKeywordFromText(pluginID: String) -> Bool {
        guard !plugins.isActive else { return false }
        let keyword: AskKeyword, argument: String
        switch AskKeywordMatcher.match(launcherDraft.text, keywords: plugins.availableKeywords) {
        case let .hint(found): keyword = found; argument = ""
        case let .active(found, text): keyword = found; argument = text
        case nil: return false
        }
        guard keyword.pluginID == pluginID else { return false }
        plugins.enter(keyword)
        launcherDraft.text = argument
        plugins.update(text: argument, selection: launcherDraft.sentSelection, language: AppLocalization.shared.language)
        return true
    }

    /// Reads the live settings and installed manifests, including disabled workflows.
    func launcherKeywordDirectory(language: AppLanguage) -> [AskPrefixPlugin.Entry] {
        let settings = modelLibrary.settings
        let keywords = settings.effectiveAskLauncherKeywords(reserving: workflows?.workflows ?? [])
        var entries = keywords.compactMap { keyword -> AskPrefixPlugin.Entry? in
            guard let plugin = plugins.plugin(for: keyword) else { return nil }
            let title = Self.chipTitle(plugin: plugin, keyword: keyword, language: language)
            let summary = AskKeywordListPresentation.summary(
                of: keyword, interface: language,
                secondLanguage: settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
            )
            return AskPrefixPlugin.Entry(keyword: keyword, title: title, detail: summary, symbol: plugin.symbol)
        }
        let available = plugins.availableKeywords
        for workflow in workflows?.workflows ?? [] {
            let plugin = AskWorkflowPlugin(workflow: workflow)
            for var keyword in plugin.defaultKeywords {
                keyword.enabled = workflow.status != .disabled
                let reachable = available.contains { $0.id == keyword.id && $0.pluginID == keyword.pluginID }
                let detail = [plugin.chipDetail(for: keyword, language: language), workflow.manifest?.description]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                entries.append(AskPrefixPlugin.Entry(
                    keyword: keyword, title: plugin.title, detail: detail, symbol: plugin.symbol,
                    unavailableReason: keyword.enabled && !reachable ? L("ask.plugin.prefix.unavailable") : nil
                ))
            }
        }
        return entries
    }
}
