import Foundation

extension AskConversationModel {
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
