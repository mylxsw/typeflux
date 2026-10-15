import Foundation

/// The four pages of the usage guide.
enum HelpPage: String, CaseIterable, Identifiable, Sendable {
    case start
    case keywords
    case shortcuts
    case faq

    var id: String { rawValue }
    var title: String { L("help.page.\(rawValue)") }
    var subtitle: String { L("help.page.\(rawValue).subtitle") }

    var symbol: String {
        switch self {
        case .start: "play.circle"
        case .keywords: "text.alignleft"
        case .shortcuts: "keyboard"
        case .faq: "questionmark.circle"
        }
    }
}

/// How the keywords page groups keywords: by what they are for.
enum HelpKeywordGroup: String, CaseIterable, Identifiable, Sendable {
    case text
    case search
    case capture
    case tools
    case mine
    case system

    var id: String { rawValue }
    var title: String { L("help.group.\(rawValue)") }

    /// A keyword the user made (or a workflow) is theirs whatever plugin it uses.
    static func of(pluginID: String, isBuiltIn: Bool) -> HelpKeywordGroup {
        if AskSystemCommand(pluginID: pluginID) != nil { return .system }
        if pluginID.hasPrefix(AskWorkflowPlugin.idPrefix) || !isBuiltIn { return .mine }
        switch pluginID {
        case AskTranslatePlugin.id, AskPromptPlugin.id:
            return .text
        case AskWebSearchPlugin.id, AskFileSearchPlugin.id, AskSemanticFileSearchPlugin.id,
             AskBrowserSearchPlugin.tabsID,
             AskBrowserSearchPlugin.bookmarksID:
            return .search
        case AskScreenshotPlugin.id, AskScreenshotTextPlugin.id:
            return .capture
        default:
            return .tools
        }
    }
}

/// One launcher keyword as the guide shows it, built from the user's current keywords.
struct HelpKeyword: Identifiable, Equatable, Sendable {
    var keyword: AskKeyword
    var title: String
    var detail: String
    var symbol: String
    var group: HelpKeywordGroup
    /// Why the keyword cannot be entered right now (switched off, its workflow is broken…).
    var unavailableReason: String?
    /// The keys of an active keyword shortcut that runs it, if there is one.
    var shortcut: [String]?
    var usageCount: Int
    var isBuiltIn: Bool
    /// Whether a lone keyword works on the text selected in the frontmost app.
    var usesSelection: Bool

    var id: String { keyword.pluginID + ":" + keyword.id }
    var isWorkflow: Bool { keyword.pluginID.hasPrefix(AskWorkflowPlugin.idPrefix) }
    var isAvailable: Bool { keyword.enabled && unavailableReason == nil }

    /// What the row says next to the title when the keyword cannot be used.
    var statusText: String? {
        if !keyword.enabled { return L("help.keyword.disabled") }
        return unavailableReason
    }

    /// Where the keyword comes from, for the detail pane.
    var origin: String {
        if group == .system { return L("help.keyword.origin.system") }
        if isWorkflow { return L("help.keyword.origin.workflow") }
        return L(isBuiltIn ? "help.keyword.origin.builtIn" : "help.keyword.origin.custom")
    }
}

/// What the guide needs to know about one keyword, read from the launcher.
struct HelpKeywordSource: Equatable, Sendable {
    var entry: AskPrefixPlugin.Entry
    var usesSelection: Bool
}

enum HelpShortcutSection: String, CaseIterable, Identifiable, Sendable {
    case global
    case keyword
    case launcher
    case result
    case chat

    var id: String { rawValue }
    var title: String { L("help.shortcuts.\(rawValue)") }
}

/// One row on the shortcuts page.
struct HelpShortcut: Identifiable, Equatable, Sendable {
    var id: String
    var section: HelpShortcutSection
    var title: String
    var detail: String
    /// Nil when the user has not assigned keys to this feature.
    var keys: [String]?
    /// The shortcut this row stands for, so an unset one can lead to its settings.
    var target: HotkeyTarget?
}

/// A `/` command typed in the launcher or the chat composer.
struct HelpCommand: Identifiable, Equatable, Sendable {
    var name: String
    var title: String
    var id: String { name }
}

/// A settings page the guide links to.
enum HelpSettingsDestination: Equatable, Sendable {
    case shortcuts
    case keywords
    case workflows
    case vocabulary
    case models
}

/// A question on the FAQ page, with where to fix the problem it describes.
struct HelpQuestion: Identifiable, Equatable, Sendable {
    var id: String
    /// A missing permission that makes this question likely.
    var permission: PrivacyGuard.PermissionID?
    var destination: HelpSettingsDestination?

    var question: String { L("help.faq.\(id).q") }
    var answer: String { L("help.faq.\(id).a") }
}

/// A permission's state on the FAQ page.
struct HelpPermissionStatus: Identifiable, Equatable, Sendable {
    var id: PrivacyGuard.PermissionID
    var title: String
    var detail: String
    var granted: Bool
}

/// Everything the guide shows, built from the user's settings so it always matches them.
struct HelpCatalog: Equatable, Sendable {
    var keywords: [HelpKeyword] = []
    var shortcuts: [HelpShortcut] = []
    var commands: [HelpCommand] = []
    var questions: [HelpQuestion] = HelpCatalog.questions
    /// Keys of voice input and of the launcher (which is also Ask), for the start page.
    var voiceKeys: [String]?
    var launcherKeys: [String]?

    func keywords(in group: HelpKeywordGroup) -> [HelpKeyword] {
        keywords.filter { $0.group == group }
    }

    /// Built-in keywords the user has never used, in the guide's own order, for "Not tried yet".
    func untriedKeywords(limit: Int = 3) -> [HelpKeyword] {
        let skipped: Set<String> = [AskHelpPlugin.id, AskPrefixPlugin.id, AskSettingsPlugin.id]
        return Array(keywords.filter {
            $0.isBuiltIn && $0.isAvailable && $0.usageCount == 0 && $0.group != .system
                && !skipped.contains($0.keyword.pluginID)
        }.prefix(limit))
    }

    func shortcuts(in section: HelpShortcutSection) -> [HelpShortcut] {
        shortcuts.filter { $0.section == section }
    }

    func keyword(id: String) -> HelpKeyword? {
        keywords.first { $0.id == id }
    }
}

/// The settings a catalog is built from.
struct HelpCatalogInput {
    var keywords: [HelpKeywordSource]
    var defaultKeywords: [AskKeyword] = AskPluginRegistry.defaultKeywords
    var builtInHotkeys: [BuiltInHotkey: HotkeyBinding]
    var actionHotkeys: [AppHotkeyAction: HotkeyBinding]
    var keywordHotkeys: [KeywordHotkey]
    /// Uses of each keyword, by `AskKeyword.id`.
    var usage: [String: Int]
}

extension HelpCatalogInput {
    /// Reads every shortcut from the settings, the same way the Shortcuts page does.
    init(keywords: [HelpKeywordSource], settings: SettingsStore, usage: [String: Int]) {
        self.init(
            keywords: keywords,
            builtInHotkeys: BuiltInHotkey.allCases.reduce(into: [:]) { result, builtIn in
                result[builtIn] = settings.hotkey(builtIn)
            },
            actionHotkeys: settings.actionHotkeys,
            keywordHotkeys: settings.keywordHotkeys,
            usage: usage
        )
    }
}

extension HelpCatalog {
    static func build(_ input: HelpCatalogInput) -> HelpCatalog {
        let askKeywords = input.keywords.map(\.entry.keyword)
        let keywords = input.keywords.map { source -> HelpKeyword in
            let keyword = source.entry.keyword
            let isBuiltIn = input.defaultKeywords.contains {
                $0.pluginID == keyword.pluginID && $0.options == keyword.options
            }
            let shortcut = input.keywordHotkeys.first { hotkey in
                guard hotkey.isActive(in: askKeywords), let resolved = hotkey.resolve(in: askKeywords) else {
                    return false
                }
                return resolved.id == keyword.id && resolved.pluginID == keyword.pluginID
            }?.binding.map(HelpKeys.keys)
            return HelpKeyword(
                keyword: keyword, title: source.entry.title, detail: source.entry.detail,
                symbol: source.entry.symbol,
                group: HelpKeywordGroup.of(pluginID: keyword.pluginID, isBuiltIn: isBuiltIn),
                unavailableReason: source.entry.unavailableReason, shortcut: shortcut,
                usageCount: input.usage[keyword.id] ?? 0, isBuiltIn: isBuiltIn,
                usesSelection: source.usesSelection
            )
        }
        return HelpCatalog(
            keywords: keywords,
            shortcuts: globalShortcuts(input) + keywordShortcuts(input, keywords: keywords) + fixedShortcuts,
            commands: commands,
            voiceKeys: input.builtInHotkeys[.activation].map(HelpKeys.keys),
            launcherKeys: input.builtInHotkeys[.ask].map(HelpKeys.keys)
        )
    }

    /// Typeflux's own shortcuts, with the keys the user gave them. Ask has no shortcut of its
    /// own any more: it is the launcher, so the launcher row covers both.
    static func globalShortcuts(_ input: HelpCatalogInput) -> [HelpShortcut] {
        let builtIns = BuiltInHotkey.allCases.map { builtIn in
            HelpShortcut(
                id: "builtIn." + builtIn.rawValue, section: .global, title: builtIn.title,
                detail: L("hotkeys.builtIn.\(builtIn.rawValue).subtitle"),
                keys: input.builtInHotkeys[builtIn].map(HelpKeys.keys), target: .builtIn(builtIn)
            )
        }
        let actions = AppHotkeyAction.allCases.map { action in
            HelpShortcut(
                id: "action." + action.rawValue, section: .global, title: action.title,
                detail: L("hotkeys.action.\(action.rawValue).subtitle"),
                keys: input.actionHotkeys[action].map(HelpKeys.keys), target: .action(action)
            )
        }
        return builtIns + actions
    }

    /// Keyword shortcuts with keys, named after the keyword they run.
    static func keywordShortcuts(_ input: HelpCatalogInput, keywords: [HelpKeyword]) -> [HelpShortcut] {
        let askKeywords = keywords.map(\.keyword)
        return input.keywordHotkeys.compactMap { hotkey in
            guard let binding = hotkey.binding else { return nil }
            let resolved = hotkey.resolve(in: askKeywords)
            let title = resolved.flatMap { found in keywords.first { $0.keyword == found }?.title }
                ?? hotkey.keyword
            let detail: String = switch KeywordHotkeyStatus(hotkey, keywords: askKeywords) {
            case .active: L("help.shortcuts.keyword.detail", hotkey.keyword)
            case .disabled: L("help.shortcuts.keyword.off")
            case .unset: ""
            case .keywordMissing: L("help.shortcuts.keyword.missing", hotkey.keyword)
            case .keywordDisabled: L("help.keyword.disabled")
            }
            return HelpShortcut(id: "keyword." + hotkey.id.uuidString, section: .keyword, title: title,
                                detail: detail, keys: HelpKeys.keys(binding), target: .keyword(hotkey.id))
        }
    }

    /// Keys inside the launcher, on its results and in the chat window. They are fixed by the
    /// app, so they live in this one table rather than being read from settings.
    /// A key the app fixes, named by `help.key.<section>.<name>`.
    struct FixedKey {
        var section: HelpShortcutSection
        var name: String
        var keys: [String]
        /// Whether the row has a second line, `help.key.<section>.<name>.detail`.
        var detailed = false

        init(_ section: HelpShortcutSection, _ name: String, _ keys: [String], detailed: Bool = false) {
            self.section = section
            self.name = name
            self.keys = keys
            self.detailed = detailed
        }
    }

    /// Built on each read so the titles follow the interface language.
    static var fixedShortcuts: [HelpShortcut] {
        let rows = [
            FixedKey(.launcher, "send", ["↩"]),
            FixedKey(.launcher, "askAI", ["⌘", "↩"], detailed: true),
            FixedKey(.launcher, "enterKeyword", ["Space"]),
            FixedKey(.launcher, "complete", ["⇥"]),
            FixedKey(.launcher, "secondary", ["⌥", "↩"], detailed: true),
            FixedKey(.launcher, "copy", ["⌘", "C"]),
            FixedKey(.launcher, "more", ["→"], detailed: true),
            FixedKey(.launcher, "context", ["⌘", "K"], detailed: true),
            FixedKey(.launcher, "attach", ["⌘", "U"]),
            FixedKey(.launcher, "recent", ["↑"], detailed: true),
            FixedKey(.launcher, "commands", ["/"]),
            FixedKey(.launcher, "close", ["esc"]),
            FixedKey(.result, "saveNote", ["⌘", "S"]),
            FixedKey(.result, "openNotes", ["⌘", "B"]),
            FixedKey(.result, "openWindow", ["⌘", "O"]),
            FixedKey(.result, "undo", ["⌘", "Z"]),
            FixedKey(.chat, "send", ["↩"]),
            FixedKey(.chat, "newline", ["⇧", "↩"]),
            FixedKey(.chat, "new", ["⌘", "N"]),
            FixedKey(.chat, "search", ["⌘", "K"]),
            FixedKey(.chat, "attach", ["⌘", "U"]),
            FixedKey(.chat, "settings", ["⌘", ","])
        ]
        return rows.map { row in
            let base = "help.key.\(row.section.rawValue).\(row.name)"
            return HelpShortcut(id: "\(row.section.rawValue).\(row.name)", section: row.section, title: L(base),
                                detail: row.detailed ? L(base + ".detail") : "", keys: row.keys)
        }
    }

    /// The `/` commands, by the names `AskCommand` gives them.
    static var commands: [HelpCommand] {
        [
            ("new", "ask.command.new"), ("search", "ask.command.search"),
            ("regenerate", "ask.command.regenerate"), ("copy", "ask.command.copy"),
            ("model", "ask.command.model"), ("think", "ask.command.think"), ("local", "ask.command.local"),
            ("file", "ask.command.file"), ("folder", "ask.command.folder"),
            ("screenshot", "ask.command.screenshot"), ("selection", "ask.command.selection"),
            ("memory", "ask.command.memory"), ("remember", "ask.command.remember"),
            ("help", "ask.command.help"), ("settings", "ask.command.settings")
        ].map { HelpCommand(name: "/" + $0.0, title: L($0.1)) }
    }

    static let questions: [HelpQuestion] = [
        HelpQuestion(id: "voiceNoResponse", permission: .accessibility, destination: .shortcuts),
        HelpQuestion(id: "textNotInserted", permission: .accessibility, destination: nil),
        HelpQuestion(id: "microphone", permission: .microphone, destination: nil),
        HelpQuestion(id: "accuracy", destination: .vocabulary),
        HelpQuestion(id: "keywordNoResponse", destination: .keywords),
        HelpQuestion(id: "customKeyword", destination: .keywords),
        HelpQuestion(id: "shortcutConflict", destination: .shortcuts),
        HelpQuestion(id: "privacy", destination: .models)
    ]
}

/// Turns a binding into the keycaps the guide draws, the way the Shortcuts page names keys.
enum HelpKeys {
    static func keys(_ binding: HotkeyBinding) -> [String] {
        var keys = HotkeyFormat.components(binding)
        if let count = HotkeyFormat.pressCount(binding) { keys.append("×\(count)") }
        return keys
    }
}
