import AVFoundation
import Foundation

/// The plugins the launcher knows and the keywords they start with.
enum AskPluginRegistry {
    /// Every built-in plugin, in the order settings and the `/` palette list them.
    static let pluginIDs = [
        AskTranslatePlugin.id,
        AskPromptPlugin.id,
        AskWebSearchPlugin.id,
        AskFileSearchPlugin.id,
        AskSemanticFileSearchPlugin.id,
        AskOpenChatPlugin.id,
        AskPrefixPlugin.id,
        AskSettingsPlugin.id,
        AskHelpPlugin.id,
        AskHistoryPlugin.id,
        AskClipboardPlugin.id,
        AskNotesPlugin.id,
        AskScreenshotPlugin.id,
        AskScreenshotTextPlugin.id,
        AskBrowserSearchPlugin.tabsID,
        AskBrowserSearchPlugin.bookmarksID,
        AskKillAppPlugin.id,
        AskSystemMonitorPlugin.id,
        AskSystemInfoPlugin.id,
        AskCalendarPlugin.id,
        AskEmojiPlugin.id
    ] + AskSystemCommand.allCases.map(\.id)

    static var defaultKeywords: [AskKeyword] {
        AskKeywordAliases
            .addingEnglishNames(AskKeywordAliases
                .consolidate(AskTranslatePlugin.keywords + AskPromptPlugin.keywords + AskWebSearchPlugin
                    .keywords + AskFileSearchPlugin.keywords + AskSemanticFileSearchPlugin.keywords
                    + AskOpenChatPlugin.keywords + AskPrefixPlugin
                    .keywords + AskSettingsPlugin.keywords + AskHelpPlugin.keywords + AskHistoryPlugin.keywords + AskClipboardPlugin
                    .keywords + AskNotesPlugin.keywords + AskScreenshotPlugin.keywords
                    + AskScreenshotTextPlugin.keywords
                    + AskBrowserSearchPlugin.keywords
                    + AskKillAppPlugin.keywords
                    + AskSystemMonitorPlugin.keywords
                    + AskSystemInfoPlugin.keywords
                    + AskCalendarPlugin.keywords
                    + AskEmojiPlugin.keywords
                    + AskSystemCommand.allCases.map {
                        AskKeyword(keyword: $0.defaultKeyword, pluginID: $0.id)
                    }))
    }

    /// Default keywords that came after their plugin: `dict` and `词典` joined translation later.
    static let wordBookKeywords = AskTranslatePlugin.id + "." + AskTranslatePlugin.wordBookAction
    /// `jtai` joined the screenshot keywords later.
    static let screenshotAskKeywords = AskScreenshotPlugin.id + "." + ScreenshotFollowUp.askAI.rawValue

    /// What a saved list records as covered: every plugin, and every later group of keywords.
    static let aliasKeywords = "launcher.keywordAliases.v1"
    static let coveredGroups = pluginIDs + [wordBookKeywords, screenshotAskKeywords, aliasKeywords]

    /// The group a default keyword belongs to for `keywords(saved:known:)`.
    static func group(of keyword: AskKeyword) -> String {
        if AskSystemCommand(pluginID: keyword.pluginID) != nil { return aliasKeywords }
        if keyword.pluginID == AskScreenshotPlugin.id, ScreenshotFollowUp(options: keyword.options) == .askAI {
            return screenshotAskKeywords
        }
        return AskTranslatePlugin.opensWordBook(keyword.options) ? wordBookKeywords : keyword.pluginID
    }

    /// The keywords in use: the saved ones, plus the defaults of plugins (or later groups
    /// of a plugin's keywords) that came after they were saved. `known` lists what the
    /// saved list covers; lists saved before it existed only knew translation.
    static func keywords(saved: [AskKeyword]?, known: [String]?, reserved: Set<String> = []) -> [AskKeyword] {
        let legacyWords = Set((AskTranslatePlugin.keywords + AskPromptPlugin.keywords + AskWebSearchPlugin.keywords
                + AskFileSearchPlugin.keywords + AskOpenChatPlugin.keywords).flatMap(\.allKeywords)
            .map { $0.lowercased() })
        let defaults = defaultKeywords.compactMap { entry -> AskKeyword? in
            let words = entry.allKeywords
                .filter { legacyWords.contains($0.lowercased()) || !reserved.contains($0.lowercased()) }
            guard let first = words.first else { return nil }
            var entry = entry
            entry.keyword = first
            entry.aliases = Array(words.dropFirst())
            return entry
        }
        guard let saved else { return defaults }
        let covered = Set(known ?? [AskTranslatePlugin.id])
        var result = AskKeywordAliases.consolidate(saved)
        var taken = Set(result.flatMap(\.allKeywords).map { $0.lowercased() })
        for entry in defaults where !covered.contains(group(of: entry)) {
            if AskSystemCommand(pluginID: entry.pluginID) != nil,
               result.contains(where: { $0.pluginID == entry.pluginID }) {
                continue
            }
            let words = entry.allKeywords.filter { !taken.contains($0.lowercased()) }
            guard let first = words.first else { continue }
            var entry = entry
            entry.keyword = first
            entry.aliases = Array(words.dropFirst())
            result.append(entry)
            taken.formUnion(words.map { $0.lowercased() })
        }
        if !covered.contains(aliasKeywords) {
            result = AskKeywordAliases.addingEnglishNames(result, reserved: reserved)
        }
        return result
    }

    /// The display name of the text-processing model (the one plugins use) for result cards.
    static func modelName(_ settings: SettingsStore?) -> String {
        guard let settings else { return "AI" }
        let configuration = settings.textLLMConfiguration()
        if configuration.provider == .typefluxCloud { return configuration.provider.displayName }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { return model }
        return settings.llmModel.isEmpty ? "AI" : settings.llmModel
    }

    /// The display name of the model AI translations use: the one chosen for
    /// translation, or the text-processing model.
    static func translationModelName(_ settings: SettingsStore?, reference: String? = nil) -> String {
        guard let settings else { return "AI" }
        let reference = reference ?? settings.askTranslationSettings.modelReference
        guard !reference.isEmpty else { return modelName(settings) }
        if reference == "cloud:default" { return LLMRemoteProvider.typefluxCloud.displayName }
        return ModelRegistry.read(settings.defaults)?.resolve(reference)?.1.name ?? L("ask.models.unavailable")
    }

    /// "AI · model" on a result card, or just "AI" when the model has no name to show.
    static func sourceLabel(_ modelName: String) -> String {
        modelName.isEmpty || modelName == "AI" ? "AI" : L("ask.plugin.source.ai", modelName)
    }
}

extension SettingsStore {
    /// The launcher's keywords, with any added since they were saved.
    var effectiveAskLauncherKeywords: [AskKeyword] {
        AskPluginRegistry.keywords(saved: askLauncherKeywords, known: askLauncherKeywordPlugins)
    }

    func effectiveAskLauncherKeywords(reserving workflows: [AskWorkflow]) -> [AskKeyword] {
        let reserved = Set(workflows.flatMap { $0.manifest?.keywords.map { $0.keyword.lowercased() } ?? [] })
        return AskPluginRegistry.keywords(
            saved: askLauncherKeywords,
            known: askLauncherKeywordPlugins,
            reserved: reserved
        )
    }

    /// Saves the keywords as covering every plugin there is now.
    func saveAskLauncherKeywords(_ keywords: [AskKeyword]?) {
        askLauncherKeywords = keywords
        askLauncherKeywordPlugins = keywords == nil ? nil : AskPluginRegistry.coveredGroups
    }
}

extension AskConversationModel {
    /// The user's keywords (or each plugin's defaults until they change them), then
    /// the workflows' keywords that do not clash with them.
    var launcherKeywords: [AskKeyword] {
        let builtIn = modelLibrary.settings.effectiveAskLauncherKeywords(reserving: workflows?.workflows ?? [])
        return builtIn + AskWorkflowStore.keywords(of: workflowPlugins(), excluding: builtIn).keywords
    }

    /// The installed workflows as launcher plugins.
    func workflowPlugins() -> [AskWorkflowPlugin] {
        workflows?.plugins { [weak self] in
            (self?.launcherDraft.source, self?.launcherDraft.sourceBundleID)
        } ?? []
    }

    /// Reads the workflows folder again and gives the launcher the result.
    func refreshLauncherWorkflows() async {
        guard let workflows else { return }
        await workflows.refresh()
        plugins.replacePlugins(makeLauncherPlugins())
    }

    func makeLauncherPlugins() -> [any AskLauncherPlugin] {
        let settings = modelLibrary.settings
        return [
            AskTranslatePlugin(
                onDevice: AskOnDeviceTranslationEngine(),
                ai: translationAI,
                dictionary: translationAI as? any AskWordLookingUp,
                wordBook: wordBook?.store,
                aiName: { [weak settings] in AskPluginRegistry.translationModelName(settings) },
                serviceSettings: { [weak settings] in settings?.askTranslationSettings ?? AskTranslationSettings() },
                service: { AskServiceTranslationEngine(client: AskServiceTranslationEngine.client(for: $0)) },
                fanout: translationFanout,
                engines: translationEngineFactory.map { factory in { @Sendable service in factory.engine(for: service) } },
                serviceName: translationEngineFactory.map { factory in { @Sendable service in factory.name(for: service) } },
                secondLanguage: { [weak settings] language in
                    settings?.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: language)
                }
            ),
            AskPromptPlugin(
                generator: promptAI,
                modelName: { [weak settings] in AskPluginRegistry.modelName(settings) },
                savesNotes: notes != nil
            ),
            AskWebSearchPlugin(),
            AskFileSearchPlugin(
                index: { [weak self] in self.flatMap { $0.quickFilesEnabled ? $0.fileIndex : nil } },
                settings: { [weak settings] in settings?.askLauncherSearchSettings ?? AskLauncherSearchSettings() },
                semantic: { [weak self] in self?.semanticSearch }
            ),
            AskSemanticFileSearchPlugin(
                semantic: { [weak self] in self?.semanticSearch },
                settings: { [weak settings] in settings?.askLauncherSearchSettings ?? AskLauncherSearchSettings() }
            ),
            AskOpenChatPlugin(),
            AskPrefixPlugin(entries: { [weak self] language in
                self?.launcherKeywordDirectory(language: language) ?? []
            }),
            AskSettingsPlugin(),
            AskHelpPlugin(),
            AskHistoryPlugin(conversations: { [weak self] in await self?.launcherChatHistory() ?? .empty }),
            AskClipboardPlugin(entries: { [weak self] in self?.clipboardEntries() ?? [] }),
            AskNotesPlugin(store: notes),
            AskScreenshotPlugin(),
            AskScreenshotTextPlugin(screenshot: { [weak self] in self?.launcherScreenshot?.source },
                                    generator: promptAI,
                                    modelName: { [weak settings] in AskPluginRegistry.modelName(settings) },
                                    savesNotes: notes != nil),
            AskBrowserSearchPlugin(kind: .tab, service: browserSearch, settings: { [weak settings] in
                settings?.askBrowserSearchSettings ?? AskBrowserSearchSettings()
            }),
            AskBrowserSearchPlugin(kind: .bookmark, service: browserSearch, settings: { [weak settings] in
                settings?.askBrowserSearchSettings ?? AskBrowserSearchSettings()
            }),
            AskKillAppPlugin(),
            AskSystemMonitorPlugin(),
            AskSystemInfoPlugin(),
            AskCalendarPlugin(),
            AskEmojiPlugin(usage: { [weak self] in self?.emojiUsage.value ?? EmojiUsage() })
        ] + AskSystemCommand.allCases.map { AskSystemCommandPlugin(command: $0) } + workflowPlugins()
    }

    /// What a plugin result's action needs from the launcher afterwards.
    enum PluginActionOutcome: Equatable {
        /// The launcher closes: copied, written back, or sent to the AI.
        case close
        case stay
    }

    /// Carries out a result's action.
    // One case per kind of action; splitting it would only scatter them.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func performPluginAction(_ action: AskPluginAction) -> PluginActionOutcome {
        if plugins.plugin?.id == AskEmojiPlugin.id {
            guard plugins.isPlanCurrent, plugins.output != nil else { return .stay }
            switch action.kind {
            case let .copy(text), let .writeBack(text):
                guard selectedEmoji(copying: text) != nil else { return .stay }
            default: break
            }
        }
        // Using a result is what makes a word typed on the fly count as looked up.
        if case .toggleStar = action.kind {
            // Recording and starring are sequenced in one admitted task below.
        } else { plugins.settleWordBook() }
        switch action.kind {
        case .fileAction:
            guard let outcome = performPluginFileAction(action) else { return .stay }
            if outcome == .close { finishPluginResult(); return .close }
            return .stay
        case let .emoji(action):
            performEmojiAction(action)
            return .stay
        case let .killApp(target):
            guard plugins.plugin?.id == AskKillAppPlugin.id, plugins.isPlanCurrent,
                  plugins.output?.selected?.actions.contains(action) == true else { return .stay }
            guard AskKillAppPlugin.forceQuit(target) else {
                confirm(L("ask.plugin.kill.failed", target.app.name), for: .seconds(3))
                plugins.rerun(with: [:], selection: nil, text: launcherDraft.text,
                              language: AppLocalization.shared.language)
                return .stay
            }
            finishPluginResult()
            return .close
        case let .systemCommand(command):
            return performSystemCommand(command)
        case .openChat:
            Task { await openChatFromLauncher() }
            return .stay
        case .openSettings:
            guard let onOpenSettings else { return .stay }
            finishPluginResult()
            onOpenSettings(.settings)
            return .close
        case let .openHelp(query):
            guard let onOpenHelp else { return .stay }
            finishPluginResult()
            onOpenHelp(query)
            return .close
        case let .openConversation(id, account):
            guard session()?.owner == account, !isDeletedConversation(id) else { return .stay }
            finishPluginResult()
            openConversationFromLauncher(id)
            return .close
        case let .configureTranslation(provider):
            translationSettingsModel.edit(provider)
            return .stay
        case let .swapTranslation(text, source, target):
            launcherDraft.text = text
            plugins.rerun(with: ["source": source, "target": target], selection: nil, text: text,
                          language: AppLocalization.shared.language)
            return .stay
        case .manageTranslationLanguages:
            openURL(AskTranslationSettingsModel.languagePackagesURL)
            return .stay
        case let .downloadTranslationLanguages(source, target):
            translationSettingsModel.downloadLanguages(source: source, target: target)
            return .stay
        case .signIn:
            onSignIn()
            return .stay
        case let .pasteClipboard(id):
            return applyLauncherClipboard(id: id, paste: true)
        case let .copyClipboard(id):
            return applyLauncherClipboard(id: id, paste: false)
        case let .previewClipboard(id):
            launcherClipboardPreview = clipboardEntries().first { $0.id == id }
            if launcherClipboardPreview == nil { confirm(L("ask.plugin.clip.unavailable")) }
            return .stay
        case let .copy(text):
            if AskQuickResults.copy(text) { recordEmoji(selectedEmoji(copying: text)) }
            finishPluginResult()
            return .close
        case let .writeBack(text):
            let emoji = selectedEmoji(copying: text)
            finishPluginResult()
            writeBack(text) { [weak self] in self?.recordEmoji(emoji) }
            return .close
        case let .speak(text, language):
            speak(text, language)
            return .stay
        case let .rerun(options):
            plugins.rerun(with: options, selection: launcherDraft.sentSelection, text: launcherDraft.text,
                          language: AppLocalization.shared.language)
            return .stay
        case .compare:
            plugins.comparing.toggle()
            return .stay
        case let .askAI(prompt):
            askAIFromPlugin(prompt)
            return .close
        case let .focusBrowserTab(target):
            Task { await focusBrowserTab(target) }
            return .stay
        case let .open(url):
            if url.isFileURL, AskFileSearchPlugin.showsFileResults(for: plugins.plugin?.id) {
                guard let hit = selectedPluginFile, hit.url == url else { return .stay }
                guard performQuickFileAction(.open, hit) == .close else { return .stay }
                finishPluginResult()
                return .close
            }
            if plugins.keyword == nil { recordLauncherInput(destination: .web, label: url.host ?? "") }
            finishPluginResult()
            if url.isFileURL { fileIndex.recordOpen(url.path) }
            openURL(url)
            return .close
        case let .openIn(url, application):
            let hit = selectedPluginFile.flatMap { $0.url == url ? $0 : nil }
            if AskFileSearchPlugin.showsFileResults(for: plugins.plugin?.id), hit == nil { return .stay }
            if let hit, hit.evidence != nil, !allowsFileEvidenceAction(hit) { return .stay }
            finishPluginResult()
            // Without that application the file opens as Finder would open it.
            if !openFileInApplication(url, application) {
                openURL(url)
            }
            if let hit { fileLocationNotice(hit) }
            return .close
        case let .reveal(url):
            finishPluginResult()
            revealFile(url)
            return .close
        case .copyImage:
            // The composer owns asynchronous preparation and post-await authorization.
            return .stay
        case let .runWith(text):
            launcherDraft.text = text
            if plugins.plugin?.id == AskTranslatePlugin.id, plugins.output?.items.isEmpty == false {
                plugins.update(text: text, selection: launcherDraft.sentSelection,
                               language: AppLocalization.shared.language, runWhenPlanned: true)
            } else {
                plugins.rerun(with: [:], selection: launcherDraft.sentSelection, text: text,
                              language: AppLocalization.shared.language)
            }
            return .stay
        case let .enterKeyword(id):
            guard let keyword = plugins.availableKeywords.first(where: { $0.id == id && $0.enabled })
            else { return .stay }
            if enterLauncherWorkflow(keyword, run: true) { return .stay }
            let listsAtOnce = [
                AskPrefixPlugin.id,
                AskKillAppPlugin.id,
                AskHistoryPlugin.id,
                AskClipboardPlugin.id,
                AskNotesPlugin.id,
                AskBrowserSearchPlugin.tabsID,
                AskBrowserSearchPlugin.bookmarksID
            ]
            plugins.enter(keyword, waitingForInput: !listsAtOnce.contains(keyword.pluginID))
            launcherDraft.text = ""
            plugins.update(text: "", selection: launcherDraft.sentSelection, language: AppLocalization.shared.language)
            return .stay
        case let .editWorkflow(id, path, line):
            finishPluginResult()
            editWorkflow(id, path, line)
            return .close
        case let .fixWorkflow(id, query, error):
            finishPluginResult()
            fixWorkflow(id, query, error)
            return .close
        case let .toggleStar(lookup):
            toggleWordBookStar(lookup)
            return .stay
        case let .openWordBook(key):
            finishPluginResult()
            openWordBook(key)
            return .close
        case let .lookUpInWordBook(text):
            finishPluginResult()
            lookUpInWordBook(text)
            return .close
        case let .copyRich(text):
            AskRichCopy.copy(text)
            confirm(L("ask.plugin.copiedRich"))
            return .stay
        case .openInWindow:
            return openLauncherResultInWindow()
        case let .toggleNote(draft):
            performNotebookAction { [weak self] in await self?.toggleLauncherNote(draft) }
            return .stay
        case let .openNotes(id):
            let shown = id ?? launcherNoteID
            finishPluginResult()
            openNotes(shown)
            return .close
        case let .openNote(id):
            performNotebookAction { [weak self] in _ = await self?.openNoteInWindow(id) }
            return .stay
        case let .createNote(title):
            finishPluginResult()
            createNote(title)
            return .close
        case let .capture(mode, followUp):
            guard let onStartScreenshot else { return .stay }
            finishPluginResult()
            // Close the launcher for its screenshot command; shortcut captures keep visible app windows.
            DispatchQueue.main.async { onStartScreenshot(mode, followUp) }
            return .close
        case let .screenshotFollowUp(followUp):
            return performScreenshotFollowUp(followUp)
        case let .translate(text):
            translateInLauncher(text)
            return .stay
        }
    }

    /// Lets `session` keep looked-up words in the word book.
    func connectWordBook(to session: AskPluginSession) {
        session.recordWordBook = { [weak self] lookup in self?.recordWordBook(lookup) }
        session.beginWordBookSession = { [weak self] in self?.wordBook?.beginSession() }
    }

    /// ⌘S: stars or unstars the word and says so in the bottom bar; ⌘S again undoes it.
    func toggleWordBookStar(_ lookup: AskWordBookLookup) {
        guard let wordBook else { return }
        guard wordBookTask == nil else { confirm(L("ask.wordBook.saveFailed")); return }
        wordBookTask = Task { [weak self] in
            guard let self else { return }
            defer { wordBookTask = nil }
            do {
                try await wordBook.record(lookup)
                try Task.checkCancellation()
                let starred = try await wordBook.toggleStar(lookup)
                guard !Task.isCancelled else { return }
                plugins.showStarred(starred, key: lookup.key)
                confirm(L(starred ? "ask.wordBook.starred" : "ask.wordBook.unstarred", lookup.headword))
            } catch { if !Task.isCancelled { confirm(L("ask.wordBook.saveFailed")) } }
        }
    }

    private func recordWordBook(_ lookup: AskWordBookLookup) {
        guard let wordBook else { return }
        guard wordBookTask == nil else { confirm(L("ask.wordBook.saveFailed")); return }
        wordBookTask = Task { [weak self] in
            guard let self else { return }
            defer { wordBookTask = nil }
            do { try await wordBook.record(lookup) }
            catch { if !Task.isCancelled { confirm(L("ask.wordBook.saveFailed")) } }
        }
    }

    /// A workflow's `runKeyword`: puts `keyword argument` in the launcher and runs it,
    /// as if typed. False when no enabled keyword is called that.
    func runLauncherKeyword(_ keyword: String, argument: String, chain: [String]) -> Bool {
        guard let found = plugins.availableKeywords.first(where: { $0.enabled && $0.contains(keyword) })
        else { return false }
        launcherDraft.text = argument
        plugins.chain(to: found, text: argument, chain: chain, selection: launcherDraft.sentSelection,
                      language: AppLocalization.shared.language)
        return true
    }

    /// ⌘C: copies and keeps the launcher open, saying so in the bottom bar.
    func copyPluginText(_ text: String) {
        if plugins.plugin?.id == AskEmojiPlugin.id, selectedEmoji(copying: text) == nil { return }
        if AskQuickResults.copy(text) { recordEmoji(selectedEmoji(copying: text)) }
        confirm(L("ask.plugin.copied"))
    }

    /// ⌘↩ in keyword mode: the AI gets the plugin's prompt about its result, or
    /// the typed text (the selection rides along with the draft as always).
    func askAIFromPlugin(_ prompt: String? = nil) {
        let argument = launcherDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt ??
            (argument.isEmpty ? plugins.plugin.map { L("ask.plugin.askAI.selection", $0.title) } ?? "" : argument)
        recordLauncherInput(destination: .askAI)
        plugins.deactivate()
        launcherDraft.text = text
        // A failed submission must not save a generated prompt as abandoned input.
        launcherExecutedInput = AskLauncherInputHistory.identity(text)
        submitLauncher(recordInput: false)
    }

    /// The result was used: the next launch starts empty, out of keyword mode.
    func finishPluginResult() {
        if plugins.keyword != nil { recordLauncherInput(destination: .keyword, label: plugins.plugin?.title ?? "") }
        releaseLauncherScreenshot()
        launcherClipboardPreview = nil
        answerWorkflowApproval(false)
        plugins.deactivate()
        finishQuickResult()
    }

    /// Closing folds the keyword into its text after input history has recorded it.
    func foldLauncherKeyword() {
        releaseLauncherScreenshot()
        launcherClipboardPreview = nil
        answerWorkflowApproval(false)
        guard plugins.isActive else { return }
        if let text = plugins.deactivate(argument: launcherDraft.text) { launcherDraft.text = text }
    }

    /// Types `text` into the app the launcher came from, over its selection when
    /// it still has one. The launcher has closed by now; if typing fails the
    /// text is on the clipboard and the next launcher says so.
    func writeBack(_ text: String, onDelivered: @escaping @MainActor () -> Void = {}) {
        guard let deliverText else {
            if AskQuickResults.copy(text) { onDelivered() }
            confirm(L("ask.plugin.writeBack.failed"), for: .seconds(8))
            return
        }
        Task { [weak self] in
            // Let the source app take its own window's focus back first.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try await deliverText(text)
                onDelivered()
            } catch {
                if AskQuickResults.copy(text) { onDelivered() }
                self?.confirm(L("ask.plugin.writeBack.failed"), for: .seconds(8))
            }
        }
    }
}

/// Reads results aloud with the system voice for their language.
@MainActor
final class AskSpeaker {
    static let shared = AskSpeaker()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        synthesizer.speak(utterance)
    }
}
