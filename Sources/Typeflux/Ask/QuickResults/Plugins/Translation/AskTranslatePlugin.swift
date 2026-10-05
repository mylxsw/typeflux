import Foundation

/// Translates the text after `fy` / `tr` / `翻译`, or the selection when nothing
/// follows. On-device translation runs while typing; the selection, and anything
/// that needs the AI, waits for Return.
struct AskTranslatePlugin: AskLauncherPlugin {
    static let id = "translate"
    /// Options a keyword or the user sets: the target language, and `engine=ai` for ⌘R.
    static let targetOption = "target"
    static let engineOption = "engine"

    var onDevice: any AskTranslationEngine
    var ai: (any AskTranslationEngine)?
    var aiName: @Sendable () -> String = { "AI" }
    var detector: any AskLanguageDetecting = AskLanguageDetector()
    /// The language translations go into when the text is already in the interface language.
    var secondLanguage: @Sendable (AppLanguage) -> String = { AskTranslationLanguages.defaultSecond(for: $0) }

    var id: String { Self.id }
    var title: String { L("ask.plugin.translate.title") }
    var symbol: String { "translate" }

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
            : L("ask.plugin.translate.title")
        var values = ["target": target, "engine": local ? "device" : "ai"]
        if let source { values["source"] = source }
        return AskPluginPlan(mode: mode, title: title, meta: meta, values: values)
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput {
        let source = plan.values["source"]
        let target = plan.values["target"] ?? AskTranslationLanguages.code(for: request.interfaceLanguage)
        let usesAI = plan.values["engine"] == "ai"
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
        if !usesAI, ai != nil {
            actions.append(AskPluginAction(kind: .rerun([Self.engineOption: "ai"]), title: L("ask.plugin.action.retranslate"),
                                           symbol: "sparkles", shortcut: .commandR))
        }
        actions.append(AskPluginAction(kind: .askAI(L("ask.plugin.translate.askAI", request.text, text)),
                                       title: L("ask.quick.askAI"), symbol: "bubble.left", shortcut: nil))
        return AskPluginOutput(body: text, original: request.text, meta: plan.meta,
                               source: usesAI ? L("ask.plugin.source.ai", aiName()) : L("ask.plugin.source.device"),
                               sourceIsAI: usesAI, note: note, actions: actions)
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
