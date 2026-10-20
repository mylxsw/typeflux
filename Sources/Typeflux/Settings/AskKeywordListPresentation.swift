import Foundation

/// What a launcher keyword reaches: one of the built-in plugins or a workflow.
enum AskKeywordKind: String, CaseIterable, Sendable {
    case translate, prompt, web, apps, files, semanticFiles, tabs, bookmarks, chat, quickAsk, prefix, setting, history, clip,
         emoji, calendar, terminal, kill, system, workflow

    // One branch per built-in capability keeps keyword classification explicit.
    // swiftlint:disable:next cyclomatic_complexity
    init?(pluginID: String) {
        switch pluginID {
        case AskTranslatePlugin.id: self = .translate
        case AskPromptPlugin.id: self = .prompt
        case AskWebSearchPlugin.id: self = .web
        case AskAppSearchPlugin.id: self = .apps
        case AskKillAppPlugin.id: self = .kill
        case AskFileSearchPlugin.id: self = .files
        case AskSemanticFileSearchPlugin.id: self = .semanticFiles
        case AskBrowserSearchPlugin.tabsID: self = .tabs
        case AskBrowserSearchPlugin.bookmarksID: self = .bookmarks
        case AskOpenChatPlugin.id: self = .chat
        case AskQuickAskPlugin.id: self = .quickAsk
        case AskPrefixPlugin.id: self = .prefix
        case AskSettingsPlugin.id: self = .setting
        case AskHistoryPlugin.id: self = .history
        case AskClipboardPlugin.id: self = .clip
        case AskEmojiPlugin.id: self = .emoji
        case AskCalendarPlugin.id: self = .calendar
        case AskTerminalCommandPlugin.id: self = .terminal
        default:
            if AskSystemCommand(pluginID: pluginID) != nil { self = .system; return }
            guard pluginID.hasPrefix(AskWorkflowPlugin.idPrefix) else { return nil }
            self = .workflow
        }
    }

    /// Kinds managed on the keyword page; workflows have their own page.
    static let editableKinds: [Self] = allCases.filter { $0 != .workflow }

    /// A fixed plugin behind the kind; workflows and system commands choose one separately.
    var pluginID: String? {
        switch self {
        case .translate: AskTranslatePlugin.id
        case .prompt: AskPromptPlugin.id
        case .web: AskWebSearchPlugin.id
        case .apps: AskAppSearchPlugin.id
        case .files: AskFileSearchPlugin.id
        case .semanticFiles: AskSemanticFileSearchPlugin.id
        case .tabs: AskBrowserSearchPlugin.tabsID
        case .bookmarks: AskBrowserSearchPlugin.bookmarksID
        case .chat: AskOpenChatPlugin.id
        case .quickAsk: AskQuickAskPlugin.id
        case .prefix: AskPrefixPlugin.id
        case .setting: AskSettingsPlugin.id
        case .history: AskHistoryPlugin.id
        case .clip: AskClipboardPlugin.id
        case .kill: AskKillAppPlugin.id
        case .emoji: AskEmojiPlugin.id
        case .calendar: AskCalendarPlugin.id
        case .terminal: AskTerminalCommandPlugin.id
        case .system, .workflow: nil
        }
    }

    var title: String {
        switch self {
        case .translate: L("ask.plugin.translate.title")
        case .prompt: L("ask.plugin.prompt.title")
        case .web: L("ask.plugin.web.title")
        case .apps: L("ask.plugin.apps.title")
        case .files: L("ask.plugin.files.title")
        case .semanticFiles: L("semantic.title")
        case .tabs: L("ask.browser.tabs")
        case .bookmarks: L("ask.browser.bookmarks")
        case .chat: L("ask.openChat")
        case .quickAsk: L("ask.quickAsk.title")
        case .prefix: L("ask.plugin.prefix.title")
        case .setting: L("ask.plugin.setting.title")
        case .history: L("ask.plugin.history.title")
        case .clip: L("ask.plugin.clip.title")
        case .kill: L("ask.plugin.kill.title")
        case .emoji: L("emoji.title")
        case .calendar: L("calendar.title")
        case .terminal: L("terminal.command.title")
        case .system: L("ask.system.title")
        case .workflow: L("ask.settings.keywords.kind.workflow")
        }
    }

    /// One line under the group heading and in the "Add keyword" menu.
    var hint: String {
        L("ask.settings.keywords.kind.\(rawValue).hint")
    }

    var symbol: String {
        switch self {
        case .translate: "translate"
        case .prompt: "wand.and.stars"
        case .web: "magnifyingglass"
        case .apps: "square.grid.2x2"
        case .files: "doc.text.magnifyingglass"
        case .semanticFiles: "sparkle.magnifyingglass"
        case .tabs: "rectangle.on.rectangle"
        case .bookmarks: "bookmark"
        case .chat: "macwindow"
        case .quickAsk: "bubble.left.and.text.bubble.right"
        case .prefix: "list.bullet.rectangle"
        case .setting: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .clip: "doc.on.clipboard"
        case .kill: "xmark.app"
        case .emoji: "face.smiling"
        case .calendar: "calendar"
        case .terminal: "terminal"
        case .system: "terminal"
        case .workflow: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// A workflow's manifest keyword reserved for conflict validation in the keyword editor.
struct AskWorkflowKeywordEntry: Equatable, Sendable {
    var keyword: String
    var workflowID: String
    var workflowName: String
    var enabled: Bool
}

/// One row of Settings → Launcher → Keywords: the keyword, what it reaches, and
/// one line on what it does.
struct AskKeywordListRow: Identifiable, Equatable {
    var keyword: String
    var kind: AskKeywordKind
    var name: String
    var summary: String
    /// URLs read best monospaced.
    var monospacedSummary = false
    var enabled: Bool
    /// The built-in or custom keyword the row edits.
    var source: AskKeyword

    var id: String {
        source.pluginID + "/" + keyword.lowercased()
    }
}

/// Builds, filters and counts the keyword list. Pure, so it is tested without the settings window.
enum AskKeywordListPresentation {
    /// Only built-in and custom plugin keywords, in plugin order.
    /// Workflow entries are kept separately for save-time conflict validation.
    static func rows(keywords: [AskKeyword], interface: AppLanguage, secondLanguage: String) -> [AskKeywordListRow] {
        AskKeywordKind.editableKinds.flatMap { kind in
            keywords.filter { AskKeywordKind(pluginID: $0.pluginID) == kind }.map {
                row($0, kind: kind, interface: interface, secondLanguage: secondLanguage)
            }
        }
    }

    static func row(_ keyword: AskKeyword, kind: AskKeywordKind, interface: AppLanguage,
                    secondLanguage: String) -> AskKeywordListRow {
        AskKeywordListRow(keyword: keyword.keyword, kind: kind, name: name(of: keyword),
                          summary: summary(of: keyword, interface: interface, secondLanguage: secondLanguage),
                          monospacedSummary: kind == .web, enabled: keyword.enabled, source: keyword)
    }

    /// What the chip and the card call a built-in keyword.
    static func name(of keyword: AskKeyword) -> String {
        switch AskKeywordKind(pluginID: keyword.pluginID) {
        case .translate:
            AskTranslatePlugin
                .opensWordBook(keyword.options) ? L("ask.wordBook.title") : L("ask.plugin.translate.title")
        case .prompt:
            AskPromptPlugin.name(of: keyword.options)
        case .web:
            AskWebSearchPlugin.engine(of: keyword.options).title
        case .apps:
            L("ask.plugin.apps.title")
        case .files:
            L("ask.plugin.files.title")
        case .semanticFiles:
            L("semantic.title")
        case .tabs: L("ask.browser.tabs")
        case .bookmarks: L("ask.browser.bookmarks")
        case .quickAsk: L("ask.quickAsk.title")
        case .chat:
            L("ask.openChat")
        case .prefix:
            L("ask.plugin.prefix.title")
        case .setting:
            L("ask.plugin.setting.title")
        case .history:
            L("ask.plugin.history.title")
        case .clip:
            L("ask.plugin.clip.title")
        case .kill: L("ask.plugin.kill.title")
        case .emoji: L("emoji.title")
        case .calendar: L("calendar.title")
        case .terminal: L("terminal.command.title")
        case .system:
            AskSystemCommand(pluginID: keyword.pluginID)?.title ?? keyword.keyword
        case .workflow, nil:
            keyword.keyword
        }
    }

    /// User-facing descriptions for presets; a short first sentence for custom prompts.
    static func summary(of keyword: AskKeyword, interface: AppLanguage, secondLanguage: String) -> String {
        switch AskKeywordKind(pluginID: keyword.pluginID) {
        case .translate:
            if AskTranslatePlugin.opensWordBook(keyword.options) {
                return L("ask.settings.keywords.summary.wordBook")
            }
            if let target = keyword.options[AskTranslatePlugin.targetOption], !target.isEmpty {
                return L("ask.settings.plugins.translate.into", AskTranslationLanguages.name(target, in: interface))
            }
            let primary = AskTranslationLanguages.code(for: interface)
            return L("ask.settings.keywords.summary.auto",
                     AskTranslationLanguages.name(primary, in: interface),
                     AskTranslationLanguages.name(secondLanguage, in: interface))
        case .prompt:
            let customPrompt = keyword.options[AskPromptPlugin.promptOption]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if customPrompt?.isEmpty != false,
               let preset = keyword.options[AskPromptPlugin.presetOption]
               .flatMap(AskPromptPlugin.Preset.init(rawValue:)) {
                return L("ask.plugin.prompt.description." + preset.rawValue)
            }
            let template = AskPromptPlugin.template(of: keyword.options) ?? ""
            let first = template.replacingOccurrences(of: AskPromptPlugin.inputToken, with: "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? L("ask.settings.plugins.prompt.placeholder")
            let sentence = first.firstIndex(where: { ".!?。！？".contains($0) }).map { String(first[...$0]) } ?? first
            return String(sentence.prefix(120)) + (sentence.count > 120 ? "…" : "")
        case .web:
            return withoutScheme(AskWebSearchPlugin.engine(of: keyword.options).template)
        case .apps:
            return L("ask.settings.keywords.kind.apps.hint")
        case .files:
            return L("ask.settings.keywords.kind.files.hint")
        case .semanticFiles:
            return L("ask.settings.keywords.kind.semanticFiles.hint")
        case .tabs, .bookmarks:
            return L(
                "ask.settings.keywords.kind.\(keyword.pluginID == AskBrowserSearchPlugin.tabsID ? "tabs" : "bookmarks").hint"
            )
        case .quickAsk: return L("ask.settings.keywords.kind.quickAsk.hint")
        case .chat:
            return L("ask.settings.keywords.kind.chat.hint")
        case .prefix:
            return L("ask.settings.keywords.kind.prefix.hint")
        case .setting:
            return L("ask.settings.keywords.kind.setting.hint")
        case .history:
            return L("ask.settings.keywords.kind.history.hint")
        case .clip:
            return L("ask.settings.keywords.kind.clip.hint")
        case .kill: return L("ask.settings.keywords.kind.kill.hint")
        case .emoji: return L("emoji.summary")
        case .calendar, .terminal:
            return keyword.pluginID == AskTerminalCommandPlugin.id
                ? L("terminal.command.runIn", TerminalApplication.configured(in: keyword.options)?.title ?? "?")
                : L("ask.settings.keywords.kind.calendar.hint")
        case .system:
            return L("ask.settings.keywords.kind.system.hint")
        case .workflow, nil:
            return ""
        }
    }

    static func withoutScheme(_ url: String) -> String {
        for scheme in ["https://", "http://"] where url.lowercased().hasPrefix(scheme) {
            return String(url.dropFirst(scheme.count))
        }
        return url
    }

    /// Rows of one kind (all when nil) that mention the query in their keyword, name or summary.
    static func filter(_ rows: [AskKeywordListRow], kind: AskKeywordKind?, query: String) -> [AskKeywordListRow] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { row in
            (kind == nil || row.kind == kind)
                &&
                (words.isEmpty || (row.source.allKeywords + [row.name, row.summary])
                    .contains { $0.lowercased().contains(words) })
        }
    }

    /// How many rows each filter tab has; `nil` counts all of them.
    static func counts(_ rows: [AskKeywordListRow]) -> [AskKeywordKind?: Int] {
        var counts: [AskKeywordKind?: Int] = [nil: rows.count]
        for kind in AskKeywordKind.editableKinds {
            counts[kind] = rows.count(where: { $0.kind == kind })
        }
        return counts
    }

    /// Manifest keywords reserved for validation, in workflow order.
    static func workflowEntries(_ workflows: [AskWorkflow],
                                isEnabled: (String) -> Bool) -> [AskWorkflowKeywordEntry] {
        workflows.flatMap { workflow in
            (workflow.manifest?.keywords ?? []).map {
                AskWorkflowKeywordEntry(keyword: $0.keyword, workflowID: workflow.id,
                                        workflowName: workflow.manifest?.name ?? workflow.id,
                                        enabled: isEnabled(workflow.id) && workflow.status == .ready)
            }
        }
    }
}

/// Display sections combine related capabilities while the filter keeps specific kinds.
enum AskKeywordSection: String, CaseIterable {
    case translate, prompt, search, typeflux, system

    var kinds: [AskKeywordKind] {
        switch self {
        case .translate: [.translate]
        case .prompt: [.prompt]
        case .search: [.web, .apps, .files, .semanticFiles, .tabs, .bookmarks, .emoji]
        case .typeflux: [.chat, .quickAsk, .prefix, .setting, .history, .clip, .calendar]
        case .system: [.terminal, .kill, .system]
        }
    }

    var title: String {
        switch self {
        case .translate: AskKeywordKind.translate.title
        case .prompt: AskKeywordKind.prompt.title
        case .search: L("ask.settings.keywords.section.search")
        case .typeflux: L("ask.settings.keywords.section.typeflux")
        case .system: AskKeywordKind.system.title
        }
    }

    var symbol: String {
        switch self {
        case .translate: "translate"
        case .prompt: "wand.and.stars"
        case .search: "magnifyingglass"
        case .typeflux: "gearshape"
        case .system: "terminal"
        }
    }
}
