import Foundation

/// Translates the text after `fy` / `tr` / `翻译`, or the selection when nothing
/// follows. On-device translation runs while typing; the selection, and anything
/// that needs the AI, waits for Return.
struct AskTranslatePlugin: AskLauncherPlugin {
    static let id = "translate"
    /// Options a keyword or the user sets: the target language, and `engine=ai` for ⌘R.
    static let targetOption = "target"
    static let engineOption = "engine"
    /// Bumped by ⌘R on a word card so the AI writes a new one instead of reusing it.
    static let generationOption = "generation"

    var onDevice: any AskTranslationEngine
    var ai: (any AskTranslationEngine)?
    /// Writes word cards for single words and short phrases; nil keeps them plain translations.
    var dictionary: (any AskWordLookingUp)?
    var aiName: @Sendable () -> String = { "AI" }
    var detector: any AskLanguageDetecting = AskLanguageDetector()
    /// The language translations go into when the text is already in the interface language.
    var secondLanguage: @Sendable (AppLanguage) -> String = { AskTranslationLanguages.defaultSecond(for: $0) }

    var id: String { Self.id }
    var title: String { L("ask.plugin.translate.title") }
    var symbol: String { "translate" }
    var optionName: String? { L("ask.plugin.translate.option") }

    static let keywords = ["fy", "tr", "翻译"].map { AskKeyword(keyword: $0, pluginID: id) }
    var defaultKeywords: [AskKeyword] { Self.keywords }

    func placeholder(selectionLines: Int?) -> String {
        guard let selectionLines, selectionLines > 0 else { return L("ask.plugin.translate.placeholder") }
        return L("ask.plugin.translate.placeholder.selection", selectionLines)
    }

    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? {
        keyword.options[Self.targetOption].map { AskTranslationLanguages.name($0, in: language) }
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let primary = AskTranslationLanguages.code(for: request.interfaceLanguage)
        let second = secondLanguage(request.interfaceLanguage)
        let source = detector.detect(request.text, hints: [primary, second])
        let target = AskTranslationLanguages.target(source: source, primary: primary, second: second,
                                                    preset: request.options[Self.targetOption])
        let wantsAI = request.options[Self.engineOption] == "ai"
        let local = !wantsAI ? await onDevice.canTranslate(from: source, to: target) : false
        // Typed text may translate while typing, but only on this Mac; the
        // selection and the AI wait for Return.
        let mode: AskPluginPlan.Mode = local && request.origin == .argument ? .live : .onSubmit
        let language = request.interfaceLanguage
        var meta: [AskPluginMeta] = []
        if let source { meta.append(AskPluginMeta(text: AskTranslationLanguages.name(source, in: language))) }
        meta.append(AskPluginMeta(text: AskTranslationLanguages.name(target, in: language), emphasized: true))
        let title = request.origin == .selection
            ? L("ask.plugin.translate.selection", request.lines)
            : !local && dictionary != nil && AskWordCard.isLookup(request.text)
            ? L("ask.plugin.translate.wordCard")
            : L("ask.plugin.translate.title")
        var values = ["target": target, "engine": local ? "device" : "ai"]
        if let source { values["source"] = source }
        return AskPluginPlan(mode: mode, title: title, meta: meta, values: values)
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        let usesAI = plan.values["engine"] == "ai"
        if usesAI, let dictionary, AskWordCard.isLookup(request.text) {
            let generation = request.options[Self.generationOption] ?? "0"
            let lookup = try await dictionary.lookUp(request.text, from: source, to: target, generation: generation)
            return wordCardOutput(lookup, request: request, plan: plan, target: target, generation: generation)
        }
        let text: String
        if usesAI {
            guard let ai else { throw AskPluginFailure(message: L("ask.plugin.translate.noModel"), retry: false) }
            text = try await ai.translate(request.text, from: source, to: target)
        } else {
            text = try await onDevice.translate(request.text, from: source, to: target)
        }
        // AI was used only because this Mac cannot translate the pair: say so.
        let note = usesAI && request.options[Self.engineOption] != "ai" ? L("ask.plugin.translate.aiFallback") : nil
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
        return AskPluginOutput(body: text, original: request.text, meta: plan.meta,
                               source: usesAI ? L("ask.plugin.source.ai", aiName()) : L("ask.plugin.source.device"),
                               sourceIsAI: usesAI, note: note ?? (offersCard ? L("ask.plugin.translate.cardHint", aiName()) : nil),
                               actions: actions)
    }

    /// A word card, or what the AI said instead: a sentence's translation, or a reply it could not shape.
    private func wordCardOutput(_ lookup: AskWordLookup, request: AskPluginRequest, plan: AskPluginPlan,
                                target: String, generation: String) -> AskPluginOutput {
        let replaces = request.origin == .selection
        let writeBackTitle = L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert")
        let writeBackSymbol = replaces ? "arrow.down.to.line" : "text.insert"
        let next = [Self.engineOption: "ai", Self.generationOption: String((Int(generation) ?? 0) + 1)]
        let source = L("ask.plugin.source.ai", aiName())
        switch lookup {
        case let .card(card):
            var actions = [
                AskPluginAction(kind: .copy(card.summary), title: L("ask.plugin.action.copyDefinition"),
                                symbol: "doc.on.doc", shortcut: .enter)
            ]
            if let meaning = card.firstMeaning {
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
            return AskPluginOutput(body: card.summary, original: request.text, meta: plan.meta, source: source,
                                   sourceIsAI: true, actions: actions, wordCard: card)
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
        let primary = AskTranslationLanguages.code(for: request.interfaceLanguage)
        let second = secondLanguage(request.interfaceLanguage)
        let current = plan.values["target"] ?? primary
        let next = AskTranslationLanguages.step(from: current, by: step, primary: primary, second: second,
                                                skipping: plan.values["source"])
        return next == current ? nil : [Self.targetOption: next]
    }
}
