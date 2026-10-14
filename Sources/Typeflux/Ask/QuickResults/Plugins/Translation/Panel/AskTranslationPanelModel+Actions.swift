import Foundation

@MainActor
extension AskTranslationPanelModel {
    var stack: AskTranslationStack {
        if let stack = output?.translation {
            return stack
        }
        let primary = AskTranslationLanguages.code(for: interface)
        let second = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: interface)
        let detected = sourceLanguage ?? plugin.detector.detect(text, hints: [primary, second])
        return .init(results: [], source: detected,
                     target: targetLanguage ?? AskTranslationLanguages.target(
                         source: detected,
                         primary: primary,
                         second: second,
                         preset: nil
                     ),
                     interface: interface, submitted: false, isLookup: AskWordCard.isLookup(trimmedText),
                     replacesSelection: source == .selection, sourceIsAutomatic: sourceLanguage == nil)
    }

    func copy(number: Int, closes: Bool = false) {
        guard number > 0, stack.results.indices.contains(number - 1),
              let text = stack.results[number - 1].completedText else { return }
        onCopy(text)
        if closes, !pinned {
            dismiss()
        }
    }

    func select(_ id: String) -> Bool {
        guard let index = output?.translation?.results.firstIndex(where: { $0.id == id }) else { return false }
        output?.selectedItem = index
        return true
    }

    func moveSelection(_ step: Int) {
        guard let count = output?.translation?.results.count, count > 0 else { return }
        output?.selectedItem = min(max(0, (output?.selectedItem ?? 0) + step), count - 1)
    }

    func navigateHistory(_ step: Int) {
        guard !history.entries.isEmpty else { return }
        if historyIndex == nil {
            guard step < 0 else { return }
            historyDraft = text
            historyIndex = 0
        } else if let index = historyIndex {
            let next = index - step
            if next < 0 {
                text = historyDraft; historyIndex = nil; return
            }
            historyIndex = min(next, history.entries.count - 1)
        }
        if let index = historyIndex {
            text = history.entries[index]
        }
    }

    func clearHistory() {
        history.clear(); historyIndex = nil; historyDraft = ""
    }

    func chooseHistory(_ text: String) {
        self.text = text; historyIndex = nil
    }

    func cycleLanguage(_ step: Int) {
        let primary = AskTranslationLanguages.code(for: interface)
        let second = settings.askTranslationSecondLanguage ?? AskTranslationLanguages.defaultSecond(for: interface)
        let next = AskTranslationLanguages.step(from: stack.target, by: step, primary: primary, second: second,
                                                skipping: stack.source)
        guard next != stack.target else { return }
        let submitted = output?.translation?.submitted == true
        targetLanguage = next
        if submitted {
            translate()
        } else {
            output = nil
        }
    }

    func swapLanguages() {
        guard let translated = stack.results.first?.completedText, let source = stack.source else { return }
        let target = stack.target
        let submitted = output?.translation?.submitted == true
        text = translated
        sourceLanguage = target
        targetLanguage = source
        if submitted {
            translate()
        }
    }

    func shortcut(_ shortcut: AskPluginAction.Shortcut) {
        guard !isDirty, let action = output?.action(for: shortcut) else { return }
        if shortcut == .commandR, running {
            return
        }
        perform(action)
    }

    func perform(_ action: AskPluginAction) {
        switch action.kind {
        case let .copy(text): onCopy(text)
        case let .speak(text, language): onSpeak(text, language)
        case let .writeBack(text): onInsert(text)
        case let .rerun(options):
            rerun(options)
        case .swapTranslation: swapLanguages()
        case let .configureTranslation(provider): configuration.edit(provider)
        case .manageTranslationLanguages: onOpenURL(AskTranslationSettingsModel.languagePackagesURL)
        case .openSettings, .openWordBook: openDestination(action.kind)
        case let .toggleStar(lookup):
            let starred = plugin.wordBook?.entry(forKey: lookup.key)?.isStarred != true
            plugin.wordBook?.setStarred(starred, lookup: lookup, at: now())
            output = output?.starring(starred)
        default: break
        }
    }

    private func openDestination(_ kind: AskPluginAction.Kind) {
        if case let .openWordBook(key) = kind {
            onWordBook(key)
        } else {
            onSettings()
        }
    }

    private func rerun(_ options: [String: String]) {
        let submitted = output?.translation?.submitted == true
        if let language = options["source"] {
            sourceLanguage = language.isEmpty ? nil : language
        }
        if let language = options[AskTranslatePlugin.targetOption] {
            targetLanguage = language
        }
        if submitted || options["retryService"] != nil || options["regenerateService"] != nil {
            translate(options: options)
        } else {
            output = nil
        }
    }
}
