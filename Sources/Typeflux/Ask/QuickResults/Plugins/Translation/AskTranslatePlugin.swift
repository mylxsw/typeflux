import Foundation

/// Translates the text after `fy` / `tr` / `翻译`, or the selection when nothing
/// follows. On-device translation runs while typing; the selection, and anything
/// that goes to the AI or a translation service, waits for Return.
struct AskTranslatePlugin: AskLauncherPlugin {
    static let id = "translate"
    /// Options a keyword or the user sets: the target language, and the engine:
    /// `engine=ai` or a provider (`engine=deepl`) restricts a keyword to one service.
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
    /// The enabled services and their display order.
    var serviceSettings: @Sendable () -> AskTranslationSettings = { AskTranslationSettings() }
    /// A translation service, with its keys from the Keychain; nil leaves services out.
    var service: (@Sendable (AskTranslationProvider) -> any AskTranslationEngine)?
    var fanout: AskTranslationFanout?
    var engines: AskTranslationFanout.Engine?
    var serviceName: AskTranslationFanout.Name?
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
        let services = selectedServices(request)
        let asked = request.options[Self.engineOption]
        let chosen = asked != nil && asked != "ai"
        let kept = services.contains { $0.isAI && $0.enabled }
            && request.options["regenerateService"] == nil && request.options[Self.generationOption] == nil && !chosen
            ? await keptCard(request.text, source: source, target: target) : nil
        let local = kept == nil && services.contains { $0.enabled && $0.kind == .device }
            ? await onDevice.canTranslate(from: source, to: target) : false
        let mode: AskPluginPlan.Mode = (local || kept != nil) && request.origin == .argument ? .live : .onSubmit
        let language = request.interfaceLanguage
        var meta: [AskPluginMeta] = []
        if let source { meta.append(AskPluginMeta(text: AskTranslationLanguages.name(source, in: language))) }
        meta.append(AskPluginMeta(text: AskTranslationLanguages.name(target, in: language), emphasized: true))
        let title = request.origin == .selection
            ? L("ask.plugin.translate.selection", request.lines)
            : AskWordCard.isLookup(request.text) ? L("ask.plugin.translate.wordCard") : L("ask.plugin.translate.title")
        let engine = kept != nil ? "book" : local ? "device" : request.options[Self.engineOption] ?? "fanout"
        var values = ["target": target, "engine": engine]
        if let source { values["source"] = source }
        return AskPluginPlan(mode: mode, title: title, meta: meta, values: values)
    }

    /// The language `request` is in and the one it goes into.
    private func direction(_ request: AskPluginRequest) -> (source: String?, target: String) {
        let primary = AskTranslationLanguages.code(for: request.interfaceLanguage)
        let second = secondLanguage(request.interfaceLanguage)
        let source = request.options["source"].flatMap { $0.isEmpty ? nil : $0 } ?? detector.detect(request.text, hints: [primary, second])
        return (source, AskTranslationLanguages.target(source: source, primary: primary, second: second,
                                                       preset: request.options[Self.targetOption]))
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        if Self.opensWordBook(request.options) { return try await wordBookPreview(request, plan: plan) }
        if request.text.isEmpty {
            var output = try await recentWords(plan: plan)
            if wordBook != nil { output.actions.append(Self.openWordBookAction(key: nil)) }
            return output
        }
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        let submitted = plan.mode == .onSubmit || plan.values["submitted"] == "true"
        let services = selectedServices(request)
        let entry: AskWordBookEntry?
        var storageUnavailable = false
        do {
            entry = try await wordBook?.entry(forKey: AskWordBookEntry.key(
                headword: Self.headword(request.text), source: source, target: target))
        } catch { entry = nil; storageUnavailable = true }
        let kept = services.contains { $0.isAI && $0.enabled }
            && request.options["regenerateService"] == nil && request.options[Self.generationOption] == nil
            && (request.options[Self.engineOption] == nil || request.options[Self.engineOption] == "ai")
            ? entry?.lookup.card : nil
        let coordinator: AskTranslationFanout
        if let fanout { coordinator = fanout } else { coordinator = await MainActor.run { AskTranslationFanout() } }
        let resolve: AskTranslationFanout.Engine = engines ?? { service in
            switch service.kind {
            case .device: return onDevice
            case .ai: return ai
            case let .provider(provider): return self.service?(provider)
            }
        }
        let names: AskTranslationFanout.Name = serviceName ?? { service in
            switch service.kind {
            case .device: L("ask.translation.stack.deviceTitle")
            case .ai: AskPluginRegistry.sourceLabel(aiName())
            case let .provider(provider): provider.title
            }
        }
        let lookUp: @Sendable (AskTranslationService) -> (any AskWordLookingUp)? = { service in
            if engines != nil { return resolve(service) as? any AskWordLookingUp }
            return dictionary
        }
        let results = try await coordinator.run(.init(text: request.text, source: source, target: target,
                                               interface: request.interfaceLanguage, services: services, submitted: submitted,
                                               kept: kept, options: request.options), engine: resolve, name: names,
                                               dictionary: lookUp) { results in
            progress(stackOutput(results, request: request, plan: plan, target: target, submitted: submitted, entry: entry))
        }
        var output = stackOutput(results, request: request, plan: plan, target: target, submitted: submitted, entry: entry)
        if storageUnavailable { output.note = L("ask.wordBook.storageUnavailable") }
        return output
    }

    /// A keyword's engine override is a single service, even when disabled in settings.
    func selectedServices(_ request: AskPluginRequest) -> [AskTranslationService] {
        let settings = serviceSettings()
        guard let asked = request.options[Self.engineOption] else { return settings.services }
        if asked == "device" { return [.device] }
        if asked == "ai", var firstAI = settings.firstEnabledAI ?? settings.firstAI { firstAI.enabled = true; return [firstAI] }
        if let provider = AskTranslationProvider(rawValue: asked) { return [.provider(provider, enabled: true)] }
        return settings.services
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
    private func keptCard(_ text: String, source: String?, target: String) async -> AskWordCard? {
        guard let wordBook, AskWordCard.isLookup(text) else { return nil }
        return (try? await wordBook.entry(forKey: AskWordBookEntry.key(
            headword: Self.headword(text), source: source, target: target)))?.lookup.card
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
    func recentWords(plan: AskPluginPlan, opensWordBook: Bool = false) async throws -> AskPluginOutput {
        let starred = plan.values[Self.listOption] == "starred"
        let entries: [AskWordBookEntry]
        do {
            entries = try await wordBook?.list(AskWordBookQuery(scope: starred ? .starred : .all,
                sort: starred ? .starred : .recent, limit: Self.listedWords)) ?? []
        } catch { throw AskPluginFailure(message: L("ask.wordBook.storageUnavailable")) }
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
        let kept = await keptCard(request.text, source: source, target: target)
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
        if request.text.isEmpty { return try await recentWords(plan: plan, opensWordBook: true) }
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        let preview: String
        let label: String
        if plan.values["engine"] == "book", let card = await keptCard(request.text, source: source, target: target) {
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
