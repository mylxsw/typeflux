import Foundation

/// What a launcher keyword reaches: one of the built-in plugins or a workflow.
enum AskKeywordKind: String, CaseIterable, Sendable {
    case translate, prompt, web, files, chat, workflow

    init?(pluginID: String) {
        switch pluginID {
        case AskTranslatePlugin.id: self = .translate
        case AskPromptPlugin.id: self = .prompt
        case AskWebSearchPlugin.id: self = .web
        case AskFileSearchPlugin.id: self = .files
        case AskOpenChatPlugin.id: self = .chat
        default:
            guard pluginID.hasPrefix(AskWorkflowPlugin.idPrefix) else { return nil }
            self = .workflow
        }
    }

    /// Kinds managed on the keyword page; workflows have their own page.
    static let editableKinds: [Self] = allCases.filter { $0 != .workflow }

    /// The built-in plugin behind the kind; nil for workflows.
    var pluginID: String? {
        switch self {
        case .translate: AskTranslatePlugin.id
        case .prompt: AskPromptPlugin.id
        case .web: AskWebSearchPlugin.id
        case .files: AskFileSearchPlugin.id
        case .chat: AskOpenChatPlugin.id
        case .workflow: nil
        }
    }

    var title: String {
        switch self {
        case .translate: L("ask.plugin.translate.title")
        case .prompt: L("ask.plugin.prompt.title")
        case .web: L("ask.plugin.web.title")
        case .files: L("ask.plugin.files.title")
        case .chat: L("ask.openChat")
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
        case .files: "doc.text.magnifyingglass"
        case .chat: "macwindow"
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
        kind.rawValue + "/" + keyword.lowercased()
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
        case .files:
            L("ask.plugin.files.title")
        case .chat:
            L("ask.openChat")
        case .workflow, nil:
            keyword.keyword
        }
    }

    /// One line on what a built-in keyword does: the target language, the prompt's
    /// first line, or the search URL without its scheme.
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
            let template = AskPromptPlugin.template(of: keyword.options) ?? ""
            return template.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? L("ask.settings.plugins.prompt.placeholder")
        case .web:
            return withoutScheme(AskWebSearchPlugin.engine(of: keyword.options).template)
        case .files:
            return L("ask.settings.keywords.kind.files.hint")
        case .chat:
            return L("ask.settings.keywords.kind.chat.hint")
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
                && (words.isEmpty || [row.keyword, row.name, row.summary].contains { $0.lowercased().contains(words) })
        }
    }

    /// How many rows each filter tab has; `nil` counts all of them.
    static func counts(_ rows: [AskKeywordListRow]) -> [AskKeywordKind?: Int] {
        var counts: [AskKeywordKind?: Int] = [nil: rows.count]
        for kind in AskKeywordKind.editableKinds {
            counts[kind] = rows.filter { $0.kind == kind }.count
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
