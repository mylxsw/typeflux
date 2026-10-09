import Foundation

/// Translates the text after `fy` / `tr` / `翻译`, or the selection when nothing
/// follows. On-device translation runs while typing; the selection, and anything
/// that goes to the AI or a translation service, waits for Return.
struct AskTranslatePlugin: AskLauncherPlugin {
    static let id = "translate"
    /// Options a keyword or the user sets: the target language, and the engine:
    /// `engine=ai` for ⌘R, or a service (`engine=deepl`) a keyword always uses.
    static let targetOption = "target"
    static let engineOption = "engine"
    /// Bumped by ⌘R on a word card so the AI writes a new one instead of reusing it.
    static let generationOption = "generation"
    /// With nothing typed: the recent words, or `starred` ones only (⇥).
    static let listOption = "list"
    /// How many words `fy` alone lists.
    static let listedWords = 8
    /// `action=wordbook`: the keyword (`dict`) opens the word book and looks the word up there.
    static let actionOption = "action"
    static let wordBookAction = "wordbook"

    var onDevice: any AskTranslationEngine
    var ai: (any AskTranslationEngine)?
    /// Writes word cards for single words and short phrases; nil keeps them plain translations.
    var dictionary: (any AskWordLookingUp)?
    /// Words looked up before: a card kept there shows again without asking the AI,
    /// and every word lookup can be starred. Nil without a word book.
    var wordBook: (any AskWordBookStoring)?
    var aiName: @Sendable () -> String = { "AI" }
    /// How the engine is picked; the defaults are this Mac first, then the AI.
    var engineSettings: @Sendable () -> AskTranslationSettings = { AskTranslationSettings() }
    /// A translation service, with its keys from the Keychain; nil leaves services out.
    var service: (@Sendable (AskTranslationProvider) -> any AskTranslationEngine)?
    /// A configured service to use when the Cloud model requires sign-in.
    var signedOutFallback: @Sendable () -> AskTranslationProvider? = { nil }
    var detector: any AskLanguageDetecting = AskLanguageDetector()
    /// The language translations go into when the text is already in the interface language.
    var secondLanguage: @Sendable (AppLanguage) -> String = { AskTranslationLanguages.defaultSecond(for: $0) }

    var id: String { Self.id }
    var title: String { L("ask.plugin.translate.title") }
    var symbol: String { "translate" }
    var optionName: String? { L("ask.plugin.translate.option") }

    static let keywords = ["fy", "tr", "翻译"].map { AskKeyword(keyword: $0, pluginID: id) }
        + ["dict", "词典"].map { AskKeyword(keyword: $0, pluginID: id, options: [actionOption: wordBookAction]) }

    /// Whether a keyword's options make it open the word book rather than translate in place.
    static func opensWordBook(_ options: [String: String]) -> Bool { options[actionOption] == wordBookAction }
    var defaultKeywords: [AskKeyword] { Self.keywords }
    /// `fy` alone lists the words looked up lately.
    var runsWithoutInput: Bool { wordBook != nil }

    func placeholder(selectionLines: Int?) -> String {
        guard let selectionLines, selectionLines > 0 else { return L("ask.plugin.translate.placeholder") }
        return L("ask.plugin.translate.placeholder.selection", selectionLines)
    }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        if Self.opensWordBook(keyword.options) { return L("ask.wordBook.title") }
        let details = [keyword.options[Self.targetOption].map { AskTranslationLanguages.name($0, in: language) },
                       keyword.options[Self.engineOption].flatMap(AskTranslationProvider.init(rawValue:))?.title]
            .compactMap { $0 }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        if Self.opensWordBook(request.options) { return await wordBookPlan(request) }
        if request.text.isEmpty {
            let starred = request.options[Self.listOption] == "starred"
            return AskPluginPlan(mode: .live, title: L(starred ? "ask.wordBook.list.starred" : "ask.wordBook.list.recent"),
                                 values: [Self.listOption: starred ? "starred" : "recent"])
        }
        let (source, target) = direction(request)
        let settings = engineSettings()
        let asked = request.options[Self.engineOption]
        let wantsAI = asked == "ai"
        // A service the keyword names is used even where this Mac could translate.
        let askedService = service == nil ? nil : asked.flatMap(AskTranslationProvider.init(rawValue:))
        let chosen = wantsAI || askedService != nil
        let kept = chosen ? nil : keptCard(request.text, source: source, target: target)
        let local = !chosen && kept == nil && settings.prefersOnDevice
            ? await onDevice.canTranslate(from: source, to: target) : false
        let remote = wantsAI || service == nil ? nil : askedService ?? settings.engine.provider
        // Typed text may translate while typing, but only on this Mac; the
        // selection, the AI and translation services wait for Return.
        // A card from the word book never leaves this Mac either.
        let mode: AskPluginPlan.Mode = (local || kept != nil) && request.origin == .argument ? .live : .onSubmit
        let language = request.interfaceLanguage
        var meta: [AskPluginMeta] = []
        if let source { meta.append(AskPluginMeta(text: AskTranslationLanguages.name(source, in: language))) }
        meta.append(AskPluginMeta(text: AskTranslationLanguages.name(target, in: language), emphasized: true))
        let title = request.origin == .selection
            ? L("ask.plugin.translate.selection", request.lines)
            : kept != nil || (!local && remote == nil && dictionary != nil && AskWordCard.isLookup(request.text))
            ? L("ask.plugin.translate.wordCard")
            : L("ask.plugin.translate.title")
        let engine = kept != nil ? "book" : local ? "device" : remote?.rawValue ?? "ai"
        var values = ["target": target, "engine": engine]
        if let source { values["source"] = source }
        return AskPluginPlan(mode: mode, title: title, meta: meta, values: values)
    }

    /// The language `request` is in and the one it goes into.
    private func direction(_ request: AskPluginRequest) -> (source: String?, target: String) {
        let primary = AskTranslationLanguages.code(for: request.interfaceLanguage)
        let second = secondLanguage(request.interfaceLanguage)
        let source = detector.detect(request.text, hints: [primary, second])
        return (source, AskTranslationLanguages.target(source: source, primary: primary, second: second,
                                                       preset: request.options[Self.targetOption]))
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        if Self.opensWordBook(request.options) { return try await wordBookPreview(request, plan: plan) }
        var output: AskPluginOutput
        do {
            output = request.text.isEmpty ? recentWords(plan: plan) : try await translate(request, plan: plan)
        } catch TypefluxCloudLLMError.notLoggedIn {
            try Task.checkCancellation()
            guard plan.values["engine"] == "ai", service != nil, let provider = signedOutFallback() else {
                throw TypefluxCloudLLMError.notLoggedIn
            }
            var fallback = plan
            fallback.values["engine"] = provider.rawValue
            output = try await translate(request, plan: fallback, allowsAIFallback: false)
            output.note = L("ask.plugin.translate.signInFallback", provider.title)
        }
        // Every translation leads to the word book, on its word when it looked one up.
        if wordBook != nil { output.actions.append(Self.openWordBookAction(key: output.wordBook?.key)) }
        return output
    }

    static func openWordBookAction(key: String?) -> AskPluginAction {
        AskPluginAction(kind: .openWordBook(key: key), title: L("ask.wordBook.open"), symbol: "character.book.closed",
                        shortcut: .commandB)
    }

    private func translate(_ request: AskPluginRequest, plan: AskPluginPlan, allowsAIFallback: Bool = true) async throws -> AskPluginOutput {
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        var usesAI = plan.values["engine"] == "ai"
        let provider = plan.values["engine"].flatMap(AskTranslationProvider.init(rawValue:))
        if plan.values["engine"] == "book", let card = keptCard(request.text, source: source, target: target) {
            return wordCardOutput(.card(card), request: request, plan: plan, target: target, generation: "0", kept: true)
        }
        if usesAI, let dictionary, AskWordCard.isLookup(request.text) {
            let generation = request.options[Self.generationOption] ?? "0"
            var lookup = try await dictionary.lookUp(request.text, from: source, to: target, generation: generation)
            // A garbled structured reply is never shown as it came: translate the word plainly instead.
            if case let .unreadable(raw) = lookup, AskWordCard.looksStructured(raw), let ai {
                lookup = .unreadable(try await ai.translate(request.text, from: source, to: target))
            }
            return wordCardOutput(lookup, request: request, plan: plan, target: target, generation: generation)
        }
        let text: String
        var note: String?
        if let provider {
            let result = try await serviceTranslation(request.text, provider: provider, source: source, target: target,
                                                      allowsAIFallback: allowsAIFallback)
            text = result.text
            if let fallback = result.fallback {
                usesAI = true
                note = L("ask.plugin.translate.serviceFallback", provider.title, fallback)
            }
        } else if usesAI {
            guard let ai else { throw AskPluginFailure(message: L("ask.plugin.translate.noModel"), retry: false) }
            text = try await ai.translate(request.text, from: source, to: target)
            // AI was used only because this Mac cannot translate the pair: say so.
            if request.options[Self.engineOption] != "ai", engineSettings().prefersOnDevice {
                note = L("ask.plugin.translate.aiFallback")
            }
        } else {
            text = try await onDevice.translate(request.text, from: source, to: target)
        }
        let replaces = request.origin == .selection
        var actions = [
            AskPluginAction(kind: .copy(text), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc", shortcut: .enter),
            AskPluginAction(kind: .writeBack(text),
                            title: L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert"),
                            symbol: replaces ? "arrow.down.to.line" : "text.insert", shortcut: .optionEnter),
            AskPluginAction(kind: .speak(text, language: target), title: L("ask.plugin.action.speak"),
                            symbol: "speaker.wave.2", shortcut: nil),
            AskPluginAction(kind: .compare, title: L("ask.plugin.action.compare"), symbol: "rectangle.split.1x2",
                            shortcut: .commandD)
        ]
        // A word translated on this Mac can become a word card, which only the AI writes.
        let offersCard = !usesAI && dictionary != nil && AskWordCard.isLookup(request.text)
        if !usesAI, ai != nil || offersCard {
            actions.append(AskPluginAction(kind: .rerun([Self.engineOption: "ai"]),
                                           title: L(offersCard ? "ask.plugin.action.wordCard" : "ask.plugin.action.retranslate"),
                                           symbol: "sparkles", shortcut: .commandR))
        }
        actions.append(AskPluginAction(kind: .askAI(L("ask.plugin.translate.askAI", request.text, text)),
                                       title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil))
        let sourceLabel = usesAI ? AskPluginRegistry.sourceLabel(aiName())
            : provider?.title ?? L("ask.plugin.source.device")
        var output = AskPluginOutput(body: text, original: request.text, meta: plan.meta, source: sourceLabel,
                                     sourceIsAI: usesAI,
                                     note: note ?? (offersCard ? L("ask.plugin.translate.cardHint", aiName()) : nil),
                                     actions: actions)
        if AskWordCard.isLookup(request.text) {
            keep(AskWordBookLookup(headword: Self.headword(request.text), source: source, target: target,
                                   translation: text, model: usesAI ? aiName() : provider?.title),
                 in: &output, plan: plan)
        }
        return output
    }

    /// `text` translated by `provider`; when it fails and the AI may stand in, the
    /// AI's translation and why the service failed.
    private func serviceTranslation(_ text: String, provider: AskTranslationProvider, source: String?,
                                    target: String, allowsAIFallback: Bool) async throws -> (text: String, fallback: String?) {
        guard let engine = service?(provider) else { throw AskTranslationServiceError.notConfigured }
        do {
            return (try await engine.translate(text, from: source, to: target), nil)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let failure = Self.failure(error, provider: provider)
            guard allowsAIFallback, engineSettings().fallsBackToAI, let ai else { throw failure }
            return (try await ai.translate(text, from: source, to: target), Self.reason(error))
        }
    }

    /// What a service's failure card says; keys and quota are not fixed by trying again.
    static func failure(_ error: Error, provider: AskTranslationProvider) -> AskPluginFailure {
        let fixedByRetry: Bool = switch error as? AskTranslationServiceError {
        case .notConfigured?, .authentication?, .unsupportedLanguage?, .quota?, .tooLong?: false
        default: true
        }
        return AskPluginFailure(message: L("ask.translation.error.from", provider.title, reason(error)),
                                retry: fixedByRetry)
    }

    static func reason(_ error: Error) -> String {
        (error as? AskPluginFailure)?.message ?? error.localizedDescription
    }

    /// The word as typed, trimmed: the word book's headword.
    static func headword(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A card the word book holds for this word and direction.
    private func keptCard(_ text: String, source: String?, target: String) -> AskWordCard? {
        guard let wordBook, AskWordCard.isLookup(text) else { return nil }
        return wordBook.entry(forKey: AskWordBookEntry.key(headword: Self.headword(text), source: source, target: target))?
            .lookup.card
    }

    /// Lets the result go into the word book and be starred (⌘S). A word shown while
    /// typing counts once it settles; one the user pressed Return for, at once.
    private func keep(_ lookup: AskWordBookLookup, in output: inout AskPluginOutput, plan: AskPluginPlan) {
        guard let wordBook else { return }
        output.wordBook = lookup
        output.recordsAtOnce = plan.mode == .onSubmit
        let entry = wordBook.entry(forKey: lookup.key)
        output.detail = entry.map { L("ask.wordBook.seen", $0.lookupCount) }
        output.actions.append(Self.starAction(lookup, starred: entry?.isStarred == true))
        output.starred = entry?.isStarred == true
    }

    static func starAction(_ lookup: AskWordBookLookup, starred: Bool) -> AskPluginAction {
        AskPluginAction(kind: .toggleStar(lookup), title: L(starred ? "ask.wordBook.unstar" : "ask.wordBook.star"),
                        symbol: starred ? "star.fill" : "star", shortcut: .commandS)
    }

    /// A word card, or what the AI said instead: a sentence's translation, or a reply it could not shape.
    private func wordCardOutput(_ lookup: AskWordLookup, request: AskPluginRequest, plan: AskPluginPlan,
                                target: String, generation: String, kept: Bool = false) -> AskPluginOutput {
        let replaces = request.origin == .selection
        let writeBackTitle = L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert")
        let writeBackSymbol = replaces ? "arrow.down.to.line" : "text.insert"
        let next = [Self.engineOption: "ai", Self.generationOption: String((Int(generation) ?? 0) + 1)]
        let source = kept ? L("ask.plugin.source.wordBook") : AskPluginRegistry.sourceLabel(aiName())
        switch lookup {
        case let .card(card):
            let text = card.translatedText ?? card.summary
            var actions = [
                AskPluginAction(kind: .copy(text), title: L("ask.plugin.action.copy"),
                                symbol: "doc.on.doc", shortcut: .enter)
            ]
            if let meaning = card.translatedText {
                actions.append(AskPluginAction(kind: .writeBack(meaning), title: writeBackTitle, symbol: writeBackSymbol,
                                               shortcut: .optionEnter))
            }
            actions += [
                AskPluginAction(kind: .speak(card.headword, language: plan.values["source"]
                                    ?? (AskWordCard.containsCJK(card.headword) ? "zh-Hans" : "en")),
                                title: L("ask.plugin.action.speak"), symbol: "speaker.wave.2", shortcut: nil),
                AskPluginAction(kind: .copy(card.markdown), title: L("ask.plugin.action.copyCard"),
                                symbol: "doc.on.clipboard", shortcut: .shiftCommandC),
                AskPluginAction(kind: .rerun(next), title: L("ask.plugin.action.regenerate"), symbol: "arrow.clockwise",
                                shortcut: .commandR),
                AskPluginAction(kind: .askAI(L("ask.plugin.translate.askAI.word", card.markdown)),
                                title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil)
            ]
            var output = AskPluginOutput(body: text, original: request.text, meta: plan.meta, source: source,
                                         sourceIsAI: !kept, actions: actions, wordCard: card)
            keep(AskWordBookLookup(headword: Self.headword(request.text), source: plan.values["source"], target: target,
                                   card: card, model: kept ? nil : aiName()),
                 in: &output, plan: plan)
            return output
        case let .translation(text), let .unreadable(text):
            var note: String?
            if case .unreadable = lookup { note = L("ask.plugin.translate.cardUnreadable") }
            let actions = [
                AskPluginAction(kind: .copy(text), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc", shortcut: .enter),
                AskPluginAction(kind: .writeBack(text), title: writeBackTitle, symbol: writeBackSymbol, shortcut: .optionEnter),
                AskPluginAction(kind: .speak(text, language: target), title: L("ask.plugin.action.speak"),
                                symbol: "speaker.wave.2", shortcut: nil),
                AskPluginAction(kind: .rerun(next), title: L("ask.plugin.action.regenerate"), symbol: "arrow.clockwise",
                                shortcut: .commandR),
                AskPluginAction(kind: .askAI(L("ask.plugin.translate.askAI", request.text, text)),
                                title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil)
            ]
            return AskPluginOutput(body: text, original: request.text, meta: plan.meta, source: source, sourceIsAI: true,
                                   note: note, actions: actions)
        }
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        if request.text.isEmpty {
            return [Self.listOption: plan.values[Self.listOption] == "starred" ? "recent" : "starred"]
        }
        let primary = AskTranslationLanguages.code(for: request.interfaceLanguage)
        let second = secondLanguage(request.interfaceLanguage)
        let current = plan.values["target"] ?? primary
        let next = AskTranslationLanguages.step(from: current, by: step, primary: primary, second: second,
                                                skipping: plan.values["source"])
        return next == current ? nil : [Self.targetOption: next]
    }
}

extension AskPluginItem {
    /// A recent word's row, starred or not.
    func starring(_ starred: Bool) -> AskPluginItem {
        var item = self
        item.icon = .symbol(starred ? "star.fill" : "character.book.closed")
        item.actions = actions.map { action in
            if case let .toggleStar(lookup) = action.kind { return AskTranslatePlugin.starAction(lookup, starred: starred) }
            return action
        }
        return item
    }
}

extension AskPluginOutput {
    /// The same result with its word starred or not, and ⌘S saying what it does next.
    func starring(_ starred: Bool) -> AskPluginOutput {
        guard let lookup = wordBook else { return self }
        var output = self
        output.starred = starred
        output.actions = actions.map { action in
            if case .toggleStar = action.kind { return AskTranslatePlugin.starAction(lookup, starred: starred) }
            return action
        }
        return output
    }
}

// MARK: - Recent words

extension AskTranslatePlugin {
    /// `fy` alone: the words looked up lately (or the starred ones), and a way into the word book.
    /// Return looks a word up again, which shows its card from the word book without asking the AI.
    /// `dict` alone puts the way into the word book first and opens it on a chosen word.
    func recentWords(plan: AskPluginPlan, opensWordBook: Bool = false) -> AskPluginOutput {
        let starred = plan.values[Self.listOption] == "starred"
        let entries = wordBook?.list(AskWordBookQuery(scope: starred ? .starred : .all,
                                                      sort: starred ? .starred : .recent, limit: Self.listedWords)) ?? []
        let openAll = AskPluginItem(
            id: Self.openAllItem, title: L("ask.wordBook.list.openAll"), subtitle: L("ask.wordBook.list.openAll.detail"),
            icon: .symbol("character.book.closed"), autocomplete: nil,
            actions: [AskPluginAction(kind: .openWordBook(key: nil), title: L("ask.plugin.action.open"),
                                      symbol: "character.book.closed", shortcut: .enter)]
        )
        let rows = entries.map { Self.item($0, opensWordBook: opensWordBook) }
        let items = opensWordBook ? [openAll] + rows : rows + [openAll]
        let empty = L(starred ? "ask.wordBook.list.emptyStarred" : "ask.wordBook.list.empty")
        return AskPluginOutput(body: items.map(\.title).joined(separator: "\n"), original: "", meta: [],
                               source: L("ask.plugin.source.wordBook"), note: entries.isEmpty ? empty : nil,
                               actions: [], items: items)
    }

    static let openAllItem = "wordbook.open"

    static func item(_ entry: AskWordBookEntry, opensWordBook: Bool = false) -> AskPluginItem {
        var actions = [
            opensWordBook
                ? AskPluginAction(kind: .openWordBook(key: entry.key), title: L("ask.plugin.action.open"),
                                  symbol: "character.book.closed", shortcut: .enter)
                : AskPluginAction(kind: .runWith(entry.headword), title: L("ask.plugin.action.open"),
                                  symbol: "arrow.right", shortcut: .enter)
        ]
        if let meaning = entry.lookup.firstMeaning {
            actions.append(AskPluginAction(kind: .writeBack(meaning), title: L("ask.plugin.action.insert"),
                                           symbol: "text.insert", shortcut: .optionEnter))
        }
        actions += [
            starAction(entry.lookup, starred: entry.isStarred),
            openWordBookAction(key: entry.key)
        ]
        return AskPluginItem(id: entry.key, title: entry.headword, subtitle: entry.lookup.summary,
                             icon: .symbol(entry.isStarred ? "star.fill" : "character.book.closed"), actions: actions)
    }
}

// MARK: - dict

extension AskTranslatePlugin {
    /// `dict`: alone, the word book and the recent words; with a word, a preview made
    /// on this Mac and Return looking the word up in the word book. Nothing leaves the
    /// Mac from the launcher: the word book window asks the AI.
    func wordBookPlan(_ request: AskPluginRequest) async -> AskPluginPlan {
        if request.text.isEmpty {
            let starred = request.options[Self.listOption] == "starred"
            return AskPluginPlan(mode: .live, title: L("ask.wordBook.title"),
                                 values: [Self.listOption: starred ? "starred" : "recent"])
        }
        let (source, target) = direction(request)
        let kept = keptCard(request.text, source: source, target: target)
        let local = kept == nil ? await onDevice.canTranslate(from: source, to: target) : false
        let mode: AskPluginPlan.Mode = (local || kept != nil) && request.origin == .argument ? .live : .onSubmit
        var values = ["target": target, "engine": kept != nil ? "book" : local ? "device" : "none"]
        if let source { values["source"] = source }
        let language = request.interfaceLanguage
        var meta: [AskPluginMeta] = []
        if let source { meta.append(AskPluginMeta(text: AskTranslationLanguages.name(source, in: language))) }
        meta.append(AskPluginMeta(text: AskTranslationLanguages.name(target, in: language), emphasized: true))
        return AskPluginPlan(mode: mode, title: L("ask.wordBook.dict.title"), meta: meta, values: values,
                             actions: [Self.lookUpAction(Self.headword(request.text))])
    }

    static func lookUpAction(_ text: String) -> AskPluginAction {
        AskPluginAction(kind: .lookUpInWordBook(text), title: L("ask.wordBook.dict.lookUp"),
                        symbol: "character.book.closed", shortcut: .enter)
    }

    /// What `dict` shows while typing: the kept card's meanings, or this Mac's translation.
    func wordBookPreview(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput {
        if request.text.isEmpty { return recentWords(plan: plan, opensWordBook: true) }
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        let preview: String
        let label: String
        if plan.values["engine"] == "book", let card = keptCard(request.text, source: source, target: target) {
            preview = AskWordBookLookup(headword: request.text, source: source, target: target, card: card).summary
            label = L("ask.plugin.source.wordBook")
        } else {
            preview = try await onDevice.translate(request.text, from: source, to: target)
            label = L("ask.plugin.source.device")
        }
        return AskPluginOutput(body: preview, original: request.text, meta: plan.meta, source: label,
                               note: L("ask.wordBook.dict.hint"),
                               actions: [
                                   Self.lookUpAction(Self.headword(request.text)),
                                   AskPluginAction(kind: .copy(preview), title: L("ask.plugin.action.copy"),
                                                   symbol: "doc.on.doc", shortcut: .commandC)
                               ])
    }
}
