import Foundation

/// The keyword editor sheet's fields, checked and turned back into an `AskKeyword`
/// only when the user saves. Pure, so it is tested without the sheet.
struct AskKeywordDraft: Equatable {
    /// The keyword being edited; nil while adding one.
    let original: AskKeyword?
    let kind: AskKeywordKind
    var keyword: String
    var aliases: [String] = []
    var enabled: Bool
    /// Translation: a language code, empty for "detect the direction".
    var target: String
    /// Translation: a service the keyword always uses (`deepl`), empty for the usual engine.
    var translationService: String
    /// Translation: the keyword opens the word book (`dict`) instead of translating in place.
    var opensWordBook: Bool
    /// AI prompt and web search: the name on the chip; empty shows the preset's.
    var title: String
    /// AI prompt: the prompt, with the preset's filled in so the user sees what runs.
    var prompt: String
    /// Web search: the URL template, with the built-in engine's filled in.
    var url: String
    /// Web search: the built-in engine the URL came from.
    var engine: AskWebSearchPlugin.Engine?
    var systemCommand: AskSystemCommand = .toggleBluetooth

    init(editing keyword: AskKeyword) {
        original = keyword
        systemCommand = AskSystemCommand(pluginID: keyword.pluginID) ?? .toggleBluetooth
        kind = AskKeywordKind(pluginID: keyword.pluginID) ?? .prompt
        self.keyword = keyword.keyword
        aliases = keyword.aliases
        enabled = keyword.enabled
        target = keyword.options[AskTranslatePlugin.targetOption] ?? ""
        translationService = keyword.options[AskTranslatePlugin.engineOption]
            .flatMap(AskTranslationProvider.init(rawValue:))?.rawValue ?? ""
        opensWordBook = AskTranslatePlugin.opensWordBook(keyword.options)
        title = keyword.options[AskPromptPlugin.titleOption] ?? ""
        prompt = AskPromptPlugin.template(of: keyword.options) ?? ""
        let custom = keyword.options[AskWebSearchPlugin.urlOption]?.trimmingCharacters(in: .whitespaces) ?? ""
        engine = keyword.options[AskWebSearchPlugin.engineOption].flatMap(AskWebSearchPlugin.Engine.init(rawValue:))
            ?? (custom.isEmpty ? .google : nil)
        url = custom.isEmpty ? (engine ?? .google).template : custom
    }

    init(adding kind: AskKeywordKind) {
        original = nil
        self.kind = kind
        keyword = ""
        enabled = true
        target = ""
        translationService = ""
        opensWordBook = false
        title = ""
        prompt = ""
        engine = kind == .web ? .google : nil
        url = kind == .web ? AskWebSearchPlugin.Engine.google.template : ""
    }

    var isNew: Bool {
        original == nil
    }

    /// The prompt the keyword's preset brings, if it has one.
    var presetPrompt: String? {
        original?.options[AskPromptPlugin.presetOption]
            .flatMap(AskPromptPlugin.Preset.init(rawValue:))?.prompt
    }

    /// The name shown when the title is empty.
    var titlePlaceholder: String {
        switch kind {
        case .prompt:
            original.map { AskPromptPlugin.name(of: $0.options.filter { $0.key != AskPromptPlugin.titleOption }) }
                ?? L("ask.settings.keywords.sheet.promptNamePlaceholder")
        case .web:
            if let engine, url.trimmingCharacters(in: .whitespaces) == engine.template {
                engine.title
            } else {
                AskWebSearchPlugin.host(of: url).flatMap { $0.isEmpty ? nil : $0 }
                    ?? L("ask.settings.keywords.sheet.webNamePlaceholder")
            }
        case .translate, .files, .tabs, .bookmarks, .chat, .prefix, .setting, .history, .system, .workflow:
            ""
        }
    }

    /// What the launcher chip will say: the title, or what stands in for it.
    var displayName: String {
        switch kind {
        case .translate:
            if opensWordBook {
                L("ask.wordBook.title")
            } else {
                ([L("ask.plugin.translate.title")]
                    + [target.isEmpty ? nil : AskTranslationLanguages.name(target, in: AppLocalization.shared.language),
                       AskTranslationProvider(rawValue: translationService)?.title].compactMap(\.self))
                    .joined(separator: " · ")
            }
        case .prompt, .web:
            title.trimmingCharacters(in: .whitespaces).isEmpty ? titlePlaceholder : title
        case .chat:
            L("ask.openChat")
        case .prefix:
            L("ask.plugin.prefix.title")
        case .setting:
            L("ask.plugin.setting.title")
        case .history:
            L("ask.plugin.history.title")
        case .files:
            L("ask.plugin.files.title")
        case .tabs: L("ask.browser.tabs")
        case .bookmarks: L("ask.browser.bookmarks")
        case .system:
            systemCommand.title
        case .workflow:
            keyword
        }
    }

    /// Fills the URL with a built-in engine's.
    mutating func use(_ engine: AskWebSearchPlugin.Engine) {
        self.engine = engine
        url = engine.template
    }

    /// Puts the preset prompt back.
    mutating func restorePreset() {
        if let presetPrompt {
            prompt = presetPrompt
        }
    }

    /// Why the keyword cannot be saved beside the other built-in keywords and the
    /// workflows', naming who has it when it is taken.
    func keywordProblem(among keywords: [AskKeyword], workflows: [AskWorkflowKeywordEntry]) -> String? {
        let others = keywords.filter { $0 != original }
        var checked: [AskKeyword] = []
        for value in [keyword] + aliases {
            let word = value.trimmingCharacters(in: .whitespaces).lowercased()
            if let owner = others.first(where: { $0.contains(word) }), !word.isEmpty {
                return L("ask.workflow.editor.keywordTakenBy", value, AskKeywordListPresentation.name(of: owner))
            }
            if let owner = workflows.first(where: { $0.keyword.lowercased() == word }), !word.isEmpty {
                return L("ask.workflow.editor.keywordTakenBy", value, owner.workflowName)
            }
            if let problem = AskKeywordMatcher.problem(with: value, among: others + checked) {
                return AskKeywordList.message(for: problem)
            }
            checked.append(AskKeyword(keyword: word, pluginID: ""))
        }
        return nil
    }

    /// Why the plugin fields cannot be saved, or nil.
    var fieldProblem: String? {
        switch kind {
        case .prompt:
            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? L("ask.settings.keywords.sheet.promptRequired") : nil
        case .web:
            AskWebSearchPlugin.problem(with: url)
        case .translate, .files, .tabs, .bookmarks, .chat, .prefix, .setting, .history, .system, .workflow:
            nil
        }
    }

    func canSave(among keywords: [AskKeyword], workflows: [AskWorkflowKeywordEntry]) -> Bool {
        keywordProblem(among: keywords, workflows: workflows) == nil && fieldProblem == nil
    }

    /// The keyword to save. Options the editor does not show are kept; values equal
    /// to the preset or the built-in engine are left out so later presets show through.
    func result() -> AskKeyword {
        var options = original?.options ?? [:]
        func set(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            options[key] = trimmed.isEmpty ? nil : value
        }
        switch kind {
        case .translate:
            set(AskTranslatePlugin.targetOption, opensWordBook ? nil : target)
            set(AskTranslatePlugin.engineOption, opensWordBook ? nil : translationService)
            options[AskTranslatePlugin.actionOption] = opensWordBook ? AskTranslatePlugin.wordBookAction : nil
        case .prompt:
            set(AskPromptPlugin.titleOption, title.trimmingCharacters(in: .whitespaces))
            set(AskPromptPlugin.promptOption, prompt == presetPrompt ? nil : prompt)
        case .web:
            set(AskWebSearchPlugin.titleOption, title.trimmingCharacters(in: .whitespaces))
            let template = url.trimmingCharacters(in: .whitespaces)
            if let engine, template == engine.template {
                options[AskWebSearchPlugin.engineOption] = engine.rawValue
                options[AskWebSearchPlugin.urlOption] = nil
            } else {
                set(AskWebSearchPlugin.urlOption, template)
            }
        case .files, .tabs, .bookmarks, .chat, .prefix, .setting, .history, .system, .workflow:
            break
        }
        return AskKeyword(keyword: keyword.trimmingCharacters(in: .whitespaces),
                          pluginID: kind == .system ? systemCommand.id : original?.pluginID ?? kind.pluginID ?? "",
                          options: options, enabled: enabled,
                          aliases: aliases.map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

extension AskKeywordList {
    /// Saves an edited keyword in place of the original, or adds a new one at the
    /// end of its plugin's keywords.
    mutating func save(_ keyword: AskKeyword, replacing original: AskKeyword?) {
        if let original, let index = keywords.firstIndex(of: original) {
            keywords[index] = keyword
        } else if let last = keywords.lastIndex(where: { $0.pluginID == keyword.pluginID }) {
            keywords.insert(keyword, at: last + 1)
        } else {
            keywords.append(keyword)
        }
    }
}
