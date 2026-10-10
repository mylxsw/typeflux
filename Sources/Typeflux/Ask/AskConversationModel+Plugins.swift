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
        AskOpenChatPlugin.id,
        AskPrefixPlugin.id,
        AskSettingsPlugin.id,
        AskHistoryPlugin.id,
        AskNotesPlugin.id,
        AskBrowserSearchPlugin.tabsID,
        AskBrowserSearchPlugin.bookmarksID
    ] + AskSystemCommand.allCases.map(\.id)

    static var defaultKeywords: [AskKeyword] {
        AskKeywordAliases
            .addingEnglishNames(AskKeywordAliases
                .consolidate(AskTranslatePlugin.keywords + AskPromptPlugin.keywords + AskWebSearchPlugin
                    .keywords + AskFileSearchPlugin.keywords + AskOpenChatPlugin.keywords + AskPrefixPlugin
                    .keywords + AskSettingsPlugin.keywords + AskHistoryPlugin.keywords + AskNotesPlugin
                    .keywords + AskBrowserSearchPlugin.keywords + AskSystemCommand.allCases.map {
                        AskKeyword(keyword: $0.defaultKeyword, pluginID: $0.id)
                    }))
    }

    /// Default keywords that came after their plugin: `dict` and `词典` joined translation later.
    static let wordBookKeywords = AskTranslatePlugin.id + "." + AskTranslatePlugin.wordBookAction

    /// What a saved list records as covered: every plugin, and every later group of keywords.
    static let aliasKeywords = "launcher.keywordAliases.v1"
    static let coveredGroups = pluginIDs + [wordBookKeywords, aliasKeywords]

    /// The group a default keyword belongs to for `keywords(saved:known:)`.
    static func group(of keyword: AskKeyword) -> String {
        if AskSystemCommand(pluginID: keyword.pluginID) != nil { return aliasKeywords }
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
    static func translationModelName(_ settings: SettingsStore?) -> String {
        guard let settings else { return "AI" }
        let reference = settings.askTranslationSettings.modelReference
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
                engineSettings: { [weak settings] in settings?.askTranslationSettings ?? AskTranslationSettings() },
                service: { AskServiceTranslationEngine(client: AskServiceTranslationEngine.client(for: $0)) },
                signedOutFallback: { [weak settings] in
                    AskTranslationProvider.configuredFallback(credentials: AskKeychainTranslationCredentials(),
                                                              preferred: settings?.askTranslationSettings.engine
                                                                  .provider)
                },
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
                settings: { [weak settings] in settings?.askLauncherSearchSettings ?? AskLauncherSearchSettings() }
            ),
            AskOpenChatPlugin(),
            AskPrefixPlugin(entries: { [weak self] language in
                self?.launcherKeywordDirectory(language: language) ?? []
            }),
            AskSettingsPlugin(),
            AskHistoryPlugin(conversations: { [weak self] in await self?.launcherChatHistory() ?? .empty }),
            AskNotesPlugin(store: notes),
            AskBrowserSearchPlugin(kind: .tab, service: browserSearch, settings: { [weak settings] in
                settings?.askBrowserSearchSettings ?? AskBrowserSearchSettings()
            }),
            AskBrowserSearchPlugin(kind: .bookmark, service: browserSearch, settings: { [weak settings] in
                settings?.askBrowserSearchSettings ?? AskBrowserSearchSettings()
            })
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
        // Using a result is what makes a word typed on the fly count as looked up.
        plugins.settleWordBook()
        switch action.kind {
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
        case let .openConversation(id, account):
            guard session()?.owner == account, !isDeletedConversation(id) else { return .stay }
            finishPluginResult()
            openConversationFromLauncher(id)
            return .close
        case .signIn:
            onSignIn()
            return .stay
        case let .copy(text):
            AskQuickResults.copy(text)
            finishPluginResult()
            return .close
        case let .writeBack(text):
            finishPluginResult()
            writeBack(text)
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
            finishPluginResult()
            if url.isFileURL { fileIndex.recordOpen(url.path) }
            openURL(url)
            return .close
        case let .openIn(url, application):
            finishPluginResult()
            // Without that application the file opens as Finder would open it.
            if !openFileInApplication(url, application) {
                openURL(url)
            }
            return .close
        case let .reveal(url):
            finishPluginResult()
            revealFile(url)
            return .close
        case let .copyImage(url):
            guard AskQuickResults.copyImage(url) else { confirm(L("ask.workflow.image.copyFailed")); return .stay }
            finishPluginResult()
            return .close
        case let .runWith(text):
            launcherDraft.text = text
            plugins.rerun(with: [:], selection: launcherDraft.sentSelection, text: text,
                          language: AppLocalization.shared.language)
            return .stay
        case let .enterKeyword(id):
            guard let keyword = plugins.availableKeywords.first(where: { $0.id == id && $0.enabled })
            else { return .stay }
            let listsAtOnce = [
                AskPrefixPlugin.id,
                AskHistoryPlugin.id,
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
            toggleLauncherNote(draft)
            return .stay
        case let .openNotes(id):
            let shown = id ?? launcherNoteID
            finishPluginResult()
            openNotes(shown)
            return .close
        case let .openNote(id):
            return openNoteInWindow(id) ? .close : .stay
        }
    }

    /// Lets `session` keep looked-up words in the word book.
    func connectWordBook(to session: AskPluginSession) {
        session.recordWordBook = { [weak self] lookup in self?.wordBook?.record(lookup) }
        session.beginWordBookSession = { [weak self] in self?.wordBook?.beginSession() }
    }

    /// ⌘S: stars or unstars the word and says so in the bottom bar; ⌘S again undoes it.
    func toggleWordBookStar(_ lookup: AskWordBookLookup) {
        guard let wordBook else { return }
        let starred = wordBook.toggleStar(lookup)
        plugins.showStarred(starred, key: lookup.key)
        confirm(L(starred ? "ask.wordBook.starred" : "ask.wordBook.unstarred", lookup.headword))
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
        AskQuickResults.copy(text)
        confirm(L("ask.plugin.copied"))
    }

    /// ⌘↩ in keyword mode: the AI gets the plugin's prompt about its result, or
    /// the typed text (the selection rides along with the draft as always).
    func askAIFromPlugin(_ prompt: String? = nil) {
        let argument = launcherDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = prompt ??
            (argument.isEmpty ? plugins.plugin.map { L("ask.plugin.askAI.selection", $0.title) } ?? "" : argument)
        plugins.deactivate()
        launcherDraft.text = text
        submitLauncher()
    }

    /// The result was used: the next launch starts empty, out of keyword mode.
    func finishPluginResult() {
        answerWorkflowApproval(false)
        plugins.deactivate()
        finishQuickResult()
    }

    /// Closing the launcher in keyword mode puts the keyword back in front of
    /// its text, so the saved draft opens in the same mode next time.
    func foldLauncherKeyword() {
        answerWorkflowApproval(false)
        guard plugins.isActive else { return }
        if let text = plugins.deactivate(argument: launcherDraft.text) { launcherDraft.text = text }
    }

    /// Types `text` into the app the launcher came from, over its selection when
    /// it still has one. The launcher has closed by now; if typing fails the
    /// text is on the clipboard and the next launcher says so.
    func writeBack(_ text: String) {
        guard let deliverText else { AskQuickResults.copy(text); return }
        Task { [weak self] in
            // Let the source app take its own window's focus back first.
            try? await Task.sleep(for: .milliseconds(150))
            do {
                try await deliverText(text)
            } catch {
                AskQuickResults.copy(text)
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
