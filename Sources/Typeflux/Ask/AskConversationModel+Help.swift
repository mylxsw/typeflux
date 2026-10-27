import Foundation

/// What the usage guide reads from the launcher, and how it hands the user back to it.
extension AskConversationModel {
    /// The launcher's current keywords (renamed, added, workflows, switched off) for the guide.
    func helpKeywordSources(language: AppLanguage) -> [HelpKeywordSource] {
        launcherKeywordDirectory(language: language).map { entry in
            let plugin = plugins.plugin(for: entry.keyword)
            return HelpKeywordSource(
                entry: entry,
                usesSelection: plugin.map { $0.usesSelectionInput && !$0.runsWithoutInput } ?? false
            )
        }
    }

    /// How often each keyword was used, by `AskKeyword.id`.
    var helpKeywordUsage: [String: Int] {
        keywordUsage.usage.entries.mapValues(\.count)
    }

    /// "Try it" in the guide: opens the launcher in the keyword with `argument` typed, and
    /// leaves Return to the user so nothing runs on their behalf.
    func tryKeywordFromHelp(_ keyword: AskKeyword, argument: String) {
        let enter: @MainActor () -> Void = { [weak self] in
            self?.enterKeywordFromHelp(keyword, argument: argument, refreshingWorkflows: true)
        }
        guard let onShowLauncher else { enter(); return }
        onShowLauncher(enter)
    }

    /// A workflow's keyword may arrive while the launcher is still reading workflows, so a
    /// missing one is looked for once more before saying it is unavailable.
    func enterKeywordFromHelp(_ keyword: AskKeyword, argument: String, refreshingWorkflows: Bool) {
        guard let found = plugins.availableKeywords.first(where: {
            $0.enabled && $0.pluginID == keyword.pluginID && $0.id == keyword.id
        }) else {
            if refreshingWorkflows {
                Task { [weak self] in
                    await self?.refreshLauncherWorkflows()
                    self?.enterKeywordFromHelp(keyword, argument: argument, refreshingWorkflows: false)
                }
            } else {
                confirm(L("hotkeys.keyword.unavailable", keyword.keyword), for: .seconds(4))
            }
            return
        }
        plugins.enter(found)
        launcherDraft.text = noteCaptureInput(argument)
        plugins.update(text: launcherDraft.text, selection: launcherDraft.sentSelection,
                       language: AppLocalization.shared.language)
    }

    /// "Ask AI" when the guide has no answer: the question goes to the AI from the launcher,
    /// framed as a question about Typeflux.
    func askFromHelp(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let ask: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            plugins.deactivate()
            launcherDraft.text = L("help.askAI.prompt", text)
            submitLauncher()
        }
        guard let onShowLauncher else { ask(); return }
        onShowLauncher(ask)
    }
}
