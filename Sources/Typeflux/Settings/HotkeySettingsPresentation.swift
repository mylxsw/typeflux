import Foundation

/// The groups of the Shortcuts page, in page order.
enum HotkeyGroup: String, CaseIterable, Identifiable {
    case voice
    case launcher
    case content
    case keywords

    var id: String {
        rawValue
    }

    var title: String {
        L("hotkeys.group.\(rawValue)")
    }
}

/// One shortcut on the Shortcuts page.
struct HotkeyRow: Identifiable, Equatable {
    var target: HotkeyTarget
    var group: HotkeyGroup
    var icon: String
    var title: String
    var subtitle: String
    var binding: HotkeyBinding?
    /// Nil for shortcuts without a default (feature and keyword shortcuts).
    var defaultBinding: HotkeyBinding?
    /// Keyword shortcuts only.
    var status: KeywordHotkeyStatus?

    var id: HotkeyTarget {
        target
    }

    var isDefault: Bool {
        binding?.signature == defaultBinding?.signature
    }
}

/// A keyword a shortcut can run, for the editor's picker.
struct KeywordHotkeyOption: Identifiable, Equatable {
    var keyword: AskKeyword
    var name: String

    var id: String {
        keyword.pluginID + "/" + keyword.keyword.lowercased()
    }
}

/// Builds and filters the Shortcuts page. Pure, so it is tested without the settings window.
enum HotkeySettingsPresentation {
    static func group(of builtIn: BuiltInHotkey) -> HotkeyGroup {
        switch builtIn {
        case .activation, .auxiliary, .persona: .voice
        case .ask: .launcher
        case .history, .screenshot: .content
        }
    }

    static func group(of action: AppHotkeyAction) -> HotkeyGroup {
        switch action {
        case .openChat, .openStudio: .launcher
        case .screenshotText, .openNotes, .openWordBook: .content
        }
    }

    static func icon(of builtIn: BuiltInHotkey) -> String {
        switch builtIn {
        case .activation: "mic.fill"
        case .auxiliary: "person.wave.2"
        case .persona: "person.crop.rectangle.stack"
        case .ask: "command"
        case .history: "doc.on.clipboard"
        case .screenshot: "camera.viewfinder"
        }
    }

    static func icon(of action: AppHotkeyAction) -> String {
        switch action {
        case .openChat: "bubble.left.and.bubble.right"
        case .screenshotText: "text.viewfinder"
        case .openNotes: "note.text"
        case .openWordBook: "character.book.closed"
        case .openStudio: "macwindow"
        }
    }

    /// Every row, grouped in page order: built-in and feature shortcuts, then keyword shortcuts.
    static func rows(settingsStore: SettingsStore, keywords: [AskKeyword]) -> [HotkeyRow] {
        var rows = BuiltInHotkey.allCases.map { builtIn in
            HotkeyRow(target: .builtIn(builtIn), group: group(of: builtIn), icon: icon(of: builtIn),
                      title: builtIn.title, subtitle: L("hotkeys.builtIn.\(builtIn.rawValue).subtitle"),
                      binding: settingsStore.hotkey(builtIn), defaultBinding: builtIn.defaultBinding)
        }
        let actions = settingsStore.actionHotkeys
        rows += AppHotkeyAction.allCases.map { action in
            HotkeyRow(target: .action(action), group: group(of: action), icon: icon(of: action),
                      title: action.title, subtitle: L("hotkeys.action.\(action.rawValue).subtitle"),
                      binding: actions[action])
        }
        rows += settingsStore.keywordHotkeys.map { keywordRow($0, keywords: keywords) }
        return HotkeyGroup.allCases.flatMap { group in rows.filter { $0.group == group } }
    }

    static func keywordRow(_ hotkey: KeywordHotkey, keywords: [AskKeyword]) -> HotkeyRow {
        let keyword = hotkey.resolve(in: keywords)
        let name = keyword.map(keywordName) ?? hotkey.keyword
        return HotkeyRow(target: .keyword(hotkey.id), group: .keywords, icon: "character.cursor.ibeam",
                         title: keyword?.keyword ?? hotkey.keyword,
                         subtitle: L("hotkeys.keyword.subtitle", name),
                         binding: hotkey.binding, status: KeywordHotkeyStatus(hotkey, keywords: keywords))
    }

    static func keywordName(_ keyword: AskKeyword) -> String {
        AskKeywordListPresentation.name(of: keyword)
    }

    /// Rows whose name, description or keys contain `query`; all rows when it is empty.
    static func filter(_ rows: [HotkeyRow], query: String) -> [HotkeyRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.title, row.subtitle, row.binding.map(HotkeyFormat.display) ?? ""].contains {
                $0.localizedCaseInsensitiveContains(needle)
            }
        }
    }

    /// The keywords a shortcut can run: the launcher's own (built-in and custom) and the
    /// workflows' keywords, named as the keyword page names them.
    static func options(keywords: [AskKeyword], workflows: [AskWorkflowKeywordEntry]) -> [KeywordHotkeyOption] {
        let own = keywords.filter { !$0.keyword.isEmpty }.map {
            KeywordHotkeyOption(keyword: $0, name: keywordName($0))
        }
        let taken = Set(keywords.flatMap(\.allKeywords).map { $0.lowercased() })
        let flows = workflows.filter { !taken.contains($0.keyword.lowercased()) }.map {
            KeywordHotkeyOption(
                keyword: AskKeyword(keyword: $0.keyword, pluginID: AskWorkflowPlugin.idPrefix + $0.workflowID,
                                    enabled: $0.enabled),
                name: $0.workflowName
            )
        }
        return own + flows
    }

    /// One-click starting points for an empty list: polish, translate and web search.
    static func templates(in options: [KeywordHotkeyOption]) -> [KeywordHotkeyOption] {
        let picks: [(KeywordHotkeyOption) -> Bool] = [
            { $0.keyword.pluginID == AskPromptPlugin.id && $0.keyword.options[AskPromptPlugin.presetOption] == "polish"
            },
            { $0.keyword.pluginID == AskTranslatePlugin.id && !AskTranslatePlugin.opensWordBook($0.keyword.options) },
            { $0.keyword.pluginID == AskWebSearchPlugin.id }
        ]
        return picks.compactMap { pick in options.first { $0.keyword.enabled && pick($0) } }
    }

    static func statusMessage(_ status: KeywordHotkeyStatus) -> String? {
        switch status {
        case .active: nil
        case .disabled: L("hotkeys.keyword.status.disabled")
        case .unset: L("hotkeys.keyword.status.unset")
        case .keywordMissing: L("hotkeys.keyword.status.missing")
        case .keywordDisabled: L("hotkeys.keyword.status.keywordDisabled")
        }
    }
}
