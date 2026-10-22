import Foundation

extension AskConversationModel {
    /// What decides the launcher's searchable keyword entries.
    struct LauncherSearchEntriesKey: Equatable {
        var language: AppLanguage
        var presentation: UUID
        var keywords: [AskKeyword]
        var available: [AskKeyword]
        var workflows: [AskWorkflow]
        var secondLanguage: String?
    }

    /// `launcherSearchEntries(language:)` for typing. Building the directory reads
    /// screen recording access for each capture keyword, which is synchronous TCC
    /// IPC; doing that for every keystroke made typing lag. The entries are kept
    /// until a keyword, workflow or language changes, and each presentation of the
    /// launcher reads access again.
    func typingLauncherSearchEntries(language: AppLanguage) -> [AskLauncherSearchEntry] {
        let settings = modelLibrary.settings
        let workflows = workflows?.workflows ?? []
        let key = LauncherSearchEntriesKey(language: language, presentation: launcherPresentationID,
                                           keywords: settings.effectiveAskLauncherKeywords(reserving: workflows),
                                           available: plugins.availableKeywords, workflows: workflows,
                                           secondLanguage: settings.askTranslationSecondLanguage)
        if let cached = launcherSearchEntriesCache, cached.key == key { return cached.entries }
        let entries = launcherSearchEntries(language: language)
        launcherSearchEntriesCache = (key, entries)
        return entries
    }

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

    /// Return runs workflows with optional/no input; Tab only enters their input mode.
    func enterLauncherSearchEntry(_ entry: AskLauncherSearchEntry, run: Bool = false) {
        guard let current = launcherSearchEntries(language: AppLocalization.shared.language).first(where: { $0.id == entry.id })
        else { return }
        if enterLauncherWorkflow(current.keyword, run: run) { return }
        let listsAtOnce = [
            AskAppSearchPlugin.id, AskKillAppPlugin.id, AskPrefixPlugin.id, AskHistoryPlugin.id, AskClipboardPlugin.id, AskNotesPlugin.id,
            AskBrowserSearchPlugin.tabsID, AskBrowserSearchPlugin.bookmarksID, AskEmojiPlugin.id
        ]
        plugins.enter(current.keyword, waitingForInput: !listsAtOnce.contains(current.keyword.pluginID))
        launcherDraft.text = ""
        plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language)
    }

    /// A selected workflow with a useful empty-input result needs only one Return.
    /// Workflows requiring text and Tab completion keep waiting for input.
    @discardableResult
    func enterLauncherWorkflow(_ keyword: AskKeyword, run: Bool) -> Bool {
        guard let workflow = plugins.plugin(for: keyword) as? AskWorkflowPlugin else { return false }
        let runNow = run && workflow.runsWithoutInput
        plugins.enter(keyword, waitingForInput: !runNow)
        launcherDraft.text = ""
        plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language,
                       runWhenPlanned: runNow)
        return true
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

    /// A copy of `plugin` for labels: capture plugins answer from this
    /// presentation's read of screen recording access (synchronous TCC IPC)
    /// instead of reading it for each keyword. The registry keeps the original,
    /// so a capture still checks access when it runs.
    func launcherLabelPlugin(_ plugin: any AskLauncherPlugin) -> any AskLauncherPlugin {
        let snapshot = launcherCapturePermissions, presentation = launcherPresentationID
        if var capture = plugin as? AskScreenshotPlugin {
            let value = snapshot.granted(capture.id, presentation: presentation, read: capture.isPermissionGranted)
            capture.isPermissionGranted = { value }
            return capture
        }
        if var capture = plugin as? AskScreenshotTextPlugin {
            let value = snapshot.granted(capture.id, presentation: presentation, read: capture.isPermissionGranted)
            capture.isPermissionGranted = { value }
            return capture
        }
        return plugin
    }

    /// Reads the live settings and installed manifests, including disabled workflows.
    func launcherKeywordDirectory(language: AppLanguage) -> [AskPrefixPlugin.Entry] {
        let settings = modelLibrary.settings
        let keywords = settings.effectiveAskLauncherKeywords(reserving: workflows?.workflows ?? [])
        var entries = keywords.compactMap { keyword -> AskPrefixPlugin.Entry? in
            guard let plugin = plugins.plugin(for: keyword).map(launcherLabelPlugin) else { return nil }
            let title = Self.chipTitle(plugin: plugin, keyword: keyword, language: language)
            let summary = AskKeywordListPresentation.summary(
                of: keyword, interface: language,
                secondLanguage: settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
            )
            let detail = keyword.pluginID == AskCalendarPlugin.id
                ? AskCalendarPlugin.summary(language: language)
                : keyword.pluginID == AskWorldClockPlugin.id
                ? AskWorldClockPlugin.summary(options: keyword.options, language: language)
                : keyword.pluginID == AskTerminalCommandPlugin.id ? L("ask.settings.keywords.kind.terminal.hint") : summary
            return AskPrefixPlugin.Entry(keyword: keyword, title: title, detail: detail, symbol: plugin.symbol)
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
