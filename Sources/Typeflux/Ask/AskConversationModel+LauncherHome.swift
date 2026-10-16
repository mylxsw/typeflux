import Foundation

/// The launcher's home: what it offers before anything is typed (`AskLauncherHome`).
extension AskConversationModel {
    func launcherHome(now: Date = Date()) -> [AskLauncherHome.Section] {
        AskLauncherHome.build(launcherHomeContext(now: now))
    }

    func launcherHomeContext(now: Date = Date()) -> AskLauncherHome.Context {
        let draft = launcherDraft
        let language = AppLocalization.shared.language
        let keywords = launcherKeywords.filter(\.enabled).compactMap { keyword -> AskLauncherHome.KeywordChoice? in
            guard let plugin = plugins.plugin(for: keyword) else { return nil }
            return .init(keyword: keyword, title: Self.chipTitle(plugin: plugin, keyword: keyword, language: language),
                         symbol: plugin.symbol)
        }
        let ids = keywords.map { $0.keyword.id }
        if Set(launcherHomeFallbackKeywordIDs) != Set(ids) {
            launcherHomeFallbackKeywordIDs = ids.shuffled()
        }
        // Source metadata the user switched off says nothing about where the question comes from.
        let source = draft.sentSource.map(AskContextChips.sourceParts)
        return AskLauncherHome.Context(
            selection: draft.sentSelection,
            sourceBundleID: source == nil ? nil : draft.sourceBundleID,
            windowTitle: source.map { AskLauncherContext.shortTitle(app: $0.app, window: $0.window) },
            keywords: keywords,
            usage: keywordUsage.usage.entries.mapValues { Double($0.count) },
            lastUsed: keywordUsage.usage.entries.mapValues(\.lastUsed),
            fallbackKeywordIDs: launcherHomeFallbackKeywordIDs,
            applications: quickAppsEnabled ? appIndex.applications() : [],
            // A temporary question starts a new conversation; resuming one is not what it offers.
            conversations: draft.temporary == true ? [] : conversations,
            now: now
        )
    }

    /// What a keyword's chip says: "Translate", "Translate → Japanese", "Polish", "Google".
    static func chipTitle(plugin: any AskLauncherPlugin, keyword: AskKeyword, language: AppLanguage) -> String {
        let detail = plugin.chipDetail(for: keyword, language: language)?.trimmingCharacters(in: .whitespaces)
        guard let detail, !detail.isEmpty else { return plugin.title }
        if plugin.id == AskTranslatePlugin.id, !AskTranslatePlugin.opensWordBook(keyword.options) {
            return plugin.title + " → " + detail
        }
        // "Screenshot · Full screen", "Screenshot · Needs permission": the detail qualifies, never replaces.
        if plugin.id == AskScreenshotPlugin.id || plugin.id == AskScreenshotTextPlugin.id {
            return plugin.title + " · " + detail
        }
        return detail
    }

    /// Enters a keyword from the home. `run` runs it on the selection at once, as
    /// Return would; a workflow chip can also run when it needs no input.
    func enterLauncherKeyword(_ keyword: AskKeyword, run: Bool) {
        if !run, enterLauncherWorkflow(keyword, run: true) { return }
        plugins.enter(keyword)
        plugins.update(text: launcherDraft.text, selection: launcherDraft.sentSelection,
                       language: AppLocalization.shared.language, runWhenPlanned: run)
    }

    /// Sends a home row's question with what the launcher captured.
    func askFromLauncherHome(_ question: String) {
        launcherDraft.text = question
        submitLauncher()
    }

    /// Opens a conversation from the home in the workspace window.
    func openConversationFromLauncher(_ id: String) {
        onShowConversation?()
        Task { await select(id) }
    }
}
