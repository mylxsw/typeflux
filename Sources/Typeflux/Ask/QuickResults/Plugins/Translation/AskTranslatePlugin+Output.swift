import Foundation

extension AskTranslatePlugin {
    func stackOutput(_ results: [AskTranslationResult], request: AskPluginRequest, plan: AskPluginPlan,
                     target: String, submitted: Bool) -> AskPluginOutput {
        let first = results.first
        let card = results.compactMap(\.card).first
        var output = card.map { wordCardOutput(
            $0,
            request: request,
            plan: plan,
            target: target,
            kept: first?.fromWordBook == true
        ) }
            ?? plainOutput(first, request: request, plan: plan, target: target)
        output.actions += firstActions(first, request: request, target: target)
        if let firstAI = selectedServices(request)
            .first(where: \.isAI) {
            output.actions.append(Self.regenerateAction(firstAI.id))
        }
        if wordBook != nil {
            output.actions.append(Self.openWordBookAction(key: output.wordBook?.key))
        }
        output.recordsAtOnce = submitted
        output.source = first?.fromWordBook == true ? L("ask.plugin.source.wordBook") : first?.name ?? ""
        output.translation = AskTranslationStack(results: results, source: plan.values["source"], target: target,
                                                 interface: request.interfaceLanguage, submitted: submitted,
                                                 isLookup: AskWordCard.isLookup(request.text),
                                                 replacesSelection: request.origin == .selection,
                                                 sourceIsAutomatic: request.options["source"]?.isEmpty != false)
        return output
    }

    private func plainOutput(_ first: AskTranslationResult?, request: AskPluginRequest, plan: AskPluginPlan,
                             target: String) -> AskPluginOutput {
        let text = first?.completedText ?? ""
        var output = AskPluginOutput(body: text, original: request.text, meta: plan.meta, source: first?.name ?? "",
                                     sourceIsAI: first?.service.isAI == true, actions: [])
        if !text.isEmpty, first?.usedDictionary != true, AskWordCard.isLookup(request.text) {
            keep(AskWordBookLookup(headword: Self.headword(request.text), source: plan.values["source"], target: target,
                                   translation: text, model: first?.service.isAI == true ? aiName() : nil),
                 in: &output, plan: plan)
        }
        return output
    }

    private func firstActions(_ first: AskTranslationResult?, request: AskPluginRequest,
                              target: String) -> [AskPluginAction] {
        var actions = [AskPluginAction(kind: .compare, title: L("ask.plugin.action.compare"),
                                       symbol: "rectangle.split.1x2", shortcut: .commandD)]
        guard let text = first?.completedText else { return actions }
        actions.append(Self.copyAction(text, shortcut: .enter))
        if first?.card == nil {
            actions += [
                .init(
                    kind: .speak(text, language: target),
                    title: L("ask.plugin.action.speak"),
                    symbol: "speaker.wave.2"
                ),
                .init(
                    kind: .askAI(L("ask.plugin.translate.askAI", request.text, text)),
                    title: L("ask.quick.askAI"),
                    symbol: "bubble.left"
                )
            ]
        }
        if first?.card == nil || first?.card?.translatedText != nil {
            actions.append(Self.insertAction(text, replaces: request.origin == .selection))
        }
        return actions
    }

    static func copyAction(_ text: String, shortcut: AskPluginAction.Shortcut? = nil) -> AskPluginAction {
        .init(kind: .copy(text), title: L("ask.plugin.action.copy"), symbol: "doc.on.doc", shortcut: shortcut)
    }

    static func insertAction(_ text: String, replaces: Bool = false) -> AskPluginAction {
        .init(kind: .writeBack(text), title: L(replaces ? "ask.plugin.action.replace" : "ask.plugin.action.insert"),
              symbol: "text.insert", shortcut: .optionEnter)
    }

    static func regenerateAction(_ id: String) -> AskPluginAction {
        .init(kind: .rerun(["regenerateService": id, generationOption: UUID().uuidString]),
              title: L("ask.plugin.action.regenerate"), symbol: "arrow.clockwise", shortcut: .commandR)
    }

    static func openWordBookAction(key: String?) -> AskPluginAction {
        AskPluginAction(kind: .openWordBook(key: key), title: L("ask.wordBook.open"), symbol: "character.book.closed",
                        shortcut: .commandB)
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

    private func wordCardOutput(_ card: AskWordCard, request: AskPluginRequest, plan: AskPluginPlan,
                                target: String, kept: Bool) -> AskPluginOutput {
        let text = card.translatedText ?? card.summary
        let source = kept ? L("ask.plugin.source.wordBook") : AskPluginRegistry.sourceLabel(aiName())
        let actions = [
            AskPluginAction(kind: .speak(card.headword, language: plan.values["source"]
                                ?? (AskWordCard.containsCJK(card.headword) ? "zh-Hans" : "en")),
            title: L("ask.plugin.action.speak"), symbol: "speaker.wave.2"),
            AskPluginAction(kind: .copy(card.markdown), title: L("ask.plugin.action.copyCard"),
                            symbol: "doc.on.clipboard", shortcut: .shiftCommandC),
            AskPluginAction(kind: .askAI(L("ask.plugin.translate.askAI.word", card.markdown)),
                            title: L("ask.quick.askAI"), symbol: "bubble.left")
        ]
        var output = AskPluginOutput(body: text, original: request.text, meta: plan.meta, source: source,
                                     sourceIsAI: !kept, actions: actions, wordCard: card)
        keep(AskWordBookLookup(headword: Self.headword(request.text), source: plan.values["source"], target: target,
                               card: card, model: kept ? nil : aiName()), in: &output, plan: plan)
        return output
    }
}
