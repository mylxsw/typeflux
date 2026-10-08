import AppKit

/// What a slash command does once it is chosen.
enum AskCommandAction: Equatable, Hashable, Sendable {
    case newConversation, search, regenerate, copyAnswer
    case model, reasoning, localMode, permissionMode
    case attachFiles, attachFolder, screenshot, selection, memory, remember
    /// One of the launcher's starting points, by `AskSuggestion.key`.
    case suggestion(String)
    case skill(String)
    case mcpServer(String)
    /// Enters a launcher keyword's plugin, by `AskKeyword.id`.
    case keyword(String)
    case help, settings
    /// Rows of a submenu.
    case pickPermissionMode(AskPermissionMode)
    case pickModel(String)
    case pickReasoning(AskReasoningEffort)
}

/// One row of the command palette. `name` is what follows the slash; rows of
/// a submenu (models, reasoning levels) have no slash and are matched by title.
struct AskCommand: Equatable, Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case recent, conversation, model, context, prompts, plugins, skills, mcp, other

        var title: String { L("ask.command.group." + rawValue) }
    }

    enum Kind: Equatable, Sendable {
        /// Runs at once.
        case action
        /// Opens a list of choices.
        case submenu
        /// Switches something on or off; `on` is the current state.
        case toggle(on: Bool)
        /// Waits for text after the name, e.g. "/remember buy milk".
        case argument
        /// Adds a chip to the draft that rides with the next message.
        case token
    }

    var action: AskCommandAction
    var name: String
    var title: String
    var detail: String? = nil
    var symbol: String
    var group: Group
    var kind: Kind = .action
    /// Why it cannot run now; such rows stay listed but are skipped.
    var disabledReason: String? = nil
    /// A keyboard shortcut or the current value, shown at the trailing edge.
    var trailing: String? = nil
    var badge: String? = nil
    var aliases: [String] = []
    var selected = false
    /// Submenu rows are picked by title and show no slash.
    var plain = false

    var id: String { group.rawValue + "/" + name }
    var enabled: Bool { disabledReason == nil }
}

/// The state the catalog reads; built by the composer from the model so the
/// catalog stays a pure function that tests can drive.
struct AskCommandContext: Equatable, Sendable {
    struct Model: Equatable, Sendable {
        var reference: String
        var name: String
        var vision: Bool
    }

    var permissionMode: AskPermissionMode = .standard
    var launcher = false
    var busy = false
    var hasAnswer = false
    var models: [Model] = []
    var currentModel = ""
    var reasoningAvailable = false
    var reasoning: AskReasoningEffort = .providerDefault
    /// The levels the current model offers; "Auto" is always listed too.
    var reasoningLevels: [AskReasoningEffort] = AskReasoningEffort.defaultLevels
    /// The conversation is kept on this Mac.
    var localMode = false
    /// Why the conversation's storage cannot change, e.g. it has already started.
    var storageLocked: String?
    var screenshotOn = false
    /// Why a screenshot cannot be attached, e.g. the model cannot read images.
    var screenshotUnavailable: String?
    var selectionAvailable = false
    var selectionOn = false
    var memoryOn = true
    var skills: [AskSkillSummary] = []
    var mcpServers: [AskMCPServerSummary] = []
    var chosenSkills: [String] = []
    var chosenServers: [String] = []
    var recent: [String] = []
    /// The launcher's keywords and their plugins, for the plugins group.
    var keywords: [Keyword] = []

    struct Keyword: Equatable, Sendable {
        var keyword: String
        var id: String
        var title: String
        var detail: String?
        var symbol: String
    }
}

struct AskSkillSummary: Equatable, Sendable {
    var name: String
    var description: String
    var builtin: Bool
}

struct AskMCPServerSummary: Equatable, Sendable {
    var name: String
    var enabled: Bool
}

enum AskCommandCatalog {
    /// Every command for the context, grouped in display order. Only things the
    /// window already offers elsewhere are here; the palette is a faster way in.
    static func commands(_ context: AskCommandContext) -> [AskCommand] {
        let busy = context.busy ? L("ask.command.disabled.busy") : nil
        var result: [AskCommand] = [
            AskCommand(action: .newConversation, name: "new", title: L("ask.command.new"), symbol: "square.and.pencil",
                       group: .conversation, trailing: "⌘N", aliases: ["clear", "xin"]),
            AskCommand(action: .search, name: "search", title: L("ask.command.search"), symbol: "magnifyingglass",
                       group: .conversation, trailing: "⌘K", aliases: ["find", "sousuo"]),
            AskCommand(action: .regenerate, name: "regenerate", title: L("ask.command.regenerate"), symbol: "arrow.clockwise",
                       group: .conversation,
                       disabledReason: context.launcher || !context.hasAnswer ? L("ask.command.disabled.noAnswer") : busy,
                       aliases: ["retry"]),
            AskCommand(action: .copyAnswer, name: "copy", title: L("ask.command.copy"), symbol: "doc.on.doc",
                       group: .conversation,
                       disabledReason: context.launcher || !context.hasAnswer ? L("ask.command.disabled.noAnswer") : nil),
            AskCommand(action: .permissionMode, name: "mode", title: L("ask.mode.title"), symbol: "checkmark.shield",
                       group: .conversation, kind: .submenu, trailing: context.permissionMode.title),
            AskCommand(action: .model, name: "model", title: L("ask.command.model"), symbol: "cpu", group: .model,
                       kind: .submenu, disabledReason: busy,
                       trailing: context.models.first { $0.reference == context.currentModel }?.name, aliases: ["moxing", "switch"])
        ]
        if context.reasoningAvailable {
            result.append(AskCommand(action: .reasoning, name: "think", title: L("ask.command.think"), symbol: "sparkles",
                                     group: .model, kind: .submenu, disabledReason: busy, trailing: context.reasoning.label,
                                     aliases: ["reasoning", "effort"]))
        }
        result += [
            AskCommand(action: .localMode, name: "local", title: L("ask.command.local"), symbol: "lock",
                       group: .model, kind: .toggle(on: context.localMode), disabledReason: context.storageLocked,
                       aliases: ["offline", "private"]),
            AskCommand(action: .attachFiles, name: "file", title: L("ask.command.file"), symbol: "paperclip",
                       group: .context, trailing: "⌘U", aliases: ["upload", "image", "attach"]),
            AskCommand(action: .attachFolder, name: "folder", title: L("ask.command.folder"), symbol: "folder",
                       group: .context, aliases: ["directory"]),
            AskCommand(action: .screenshot, name: "screenshot", title: L("ask.command.screenshot"), symbol: "camera.viewfinder",
                       group: .context, kind: .toggle(on: context.screenshotOn),
                       disabledReason: context.screenshotOn ? nil : context.screenshotUnavailable, aliases: ["screen"]),
            AskCommand(action: .selection, name: "selection", title: L("ask.command.selection"), symbol: "text.alignleft",
                       group: .context, kind: .toggle(on: context.selectionOn),
                       disabledReason: context.selectionAvailable ? nil : L("ask.command.disabled.noSelection")),
            AskCommand(action: .memory, name: "memory", title: L("ask.command.memory"), symbol: "brain",
                       group: .context, kind: .toggle(on: context.memoryOn)),
            AskCommand(action: .remember, name: "remember", title: L("ask.command.remember"), symbol: "pin",
                       group: .context, kind: .argument, trailing: L("ask.command.remember.hint"), aliases: ["note"])
        ]
        for suggestion in AskSuggestion.all {
            let screenshot = suggestion.screenshot
            result.append(AskCommand(action: .suggestion(suggestion.key), name: promptName(suggestion.key), title: suggestion.title,
                                     detail: suggestion.caption, symbol: suggestion.systemImage, group: .prompts,
                                     disabledReason: screenshot ? context.screenshotUnavailable : nil))
        }
        if context.launcher {
            for keyword in context.keywords {
                result.append(AskCommand(action: .keyword(keyword.id), name: keyword.keyword,
                                         title: keyword.detail.map { keyword.title + " → " + $0 } ?? keyword.title,
                                         symbol: keyword.symbol, group: .plugins, aliases: ["keyword", "plugin"]))
            }
        }
        for skill in context.skills {
            result.append(AskCommand(action: .skill(skill.name), name: skill.name, title: "", detail: skill.description,
                                     symbol: "bolt", group: .skills, kind: .token,
                                     badge: L(skill.builtin ? "ask.command.badge.builtin" : "ask.command.badge.installed"),
                                     selected: context.chosenSkills.contains(skill.name)))
        }
        for server in context.mcpServers {
            result.append(AskCommand(action: .mcpServer(server.name), name: server.name, title: "",
                                     detail: L("ask.command.mcp.detail"), symbol: "powerplug", group: .mcp, kind: .token,
                                     disabledReason: server.enabled ? nil : L("ask.command.disabled.mcpOff"),
                                     selected: context.chosenServers.contains(server.name)))
        }
        result += [
            AskCommand(action: .help, name: "help", title: L("ask.command.help"), symbol: "questionmark.circle", group: .other),
            AskCommand(action: .settings, name: "settings", title: L("ask.command.settings"), symbol: "gearshape",
                       group: .other, trailing: "⌘,")
        ]
        return disambiguated(result)
    }

    /// A skill or server named like a built-in command keeps working under a prefix.
    static func disambiguated(_ commands: [AskCommand]) -> [AskCommand] {
        let builtins = Set(commands.filter { ![.plugins, .skills, .mcp].contains($0.group) }.map(\.name))
        return commands.map { command in
            var command = command
            if command.group == .plugins, builtins.contains(command.name) { command.name = "kw:" + command.name }
            if command.group == .skills, builtins.contains(command.name) { command.name = "skill:" + command.name }
            if command.group == .mcp, builtins.contains(command.name) { command.name = "mcp:" + command.name }
            return command
        }
    }

    static func promptName(_ key: String) -> String {
        switch key {
        case "ask.suggest.screen": return "explain-screen"
        case "ask.suggest.selection": return "translate"
        case "ask.suggest.page": return "summarize-page"
        default: return key.split(separator: ".").last.map(String.init) ?? key
        }
    }

    /// The choices behind a submenu command.
    static func submenu(_ action: AskCommandAction, context: AskCommandContext) -> [AskCommand] {
        switch action {
        case .permissionMode:
            return AskPermissionMode.allCases.map { mode in
                AskCommand(action: .pickPermissionMode(mode), name: mode.rawValue, title: mode.title,
                           detail: mode.detail, symbol: mode.symbol, group: .conversation,
                           selected: mode == context.permissionMode, plain: true)
            }
        case .model:
            return context.models.map { model in
                AskCommand(action: .pickModel(model.reference), name: model.name, title: "",
                           detail: L(model.vision ? "ask.command.model.vision" : "ask.command.model.text"),
                           symbol: model.vision ? "eye" : "cpu", group: .model, selected: model.reference == context.currentModel,
                           plain: true)
            }
        case .reasoning:
            return ([.providerDefault] + context.reasoningLevels).map { effort in
                AskCommand(action: .pickReasoning(effort), name: effort.label, title: "", detail: effort.caption,
                           symbol: "sparkles", group: .model, selected: effort == context.reasoning, plain: true)
            }
        default:
            return []
        }
    }

    /// Commands used recently come first, once, ahead of their groups.
    static func withRecent(_ commands: [AskCommand], recent: [String]) -> [AskCommand] {
        let byName = Dictionary(commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let recents = recent.compactMap { byName[$0] }.map { command -> AskCommand in
            var command = command
            command.group = .recent
            return command
        }
        return recents + commands
    }
}

/// Ranks commands for what is typed after the slash: a name prefix first, then
/// a word inside the name, then the title, description or an alias, then the
/// letters in order anywhere in the name.
enum AskCommandMatcher {
    struct Match: Equatable {
        var command: AskCommand
        var score: Int
        /// Matched character offsets in `command.name`, for highlighting.
        var highlights: [Int]
    }

    static func match(_ command: AskCommand, query: String) -> Match? {
        let query = query.lowercased()
        guard !query.isEmpty else { return Match(command: command, score: 1, highlights: []) }
        let name = command.name.lowercased()
        if name.hasPrefix(query) { return Match(command: command, score: 1000 - name.count, highlights: Array(0 ..< query.count)) }
        let characters = Array(name)
        for (index, character) in characters.enumerated() where index > 0 && "-:_ ".contains(characters[index - 1]) && character == query.first {
            if String(characters[index...]).hasPrefix(query) {
                return Match(command: command, score: 700 - name.count, highlights: Array(index ..< index + query.count))
            }
        }
        let haystacks = [command.title, command.detail ?? ""].map { $0.lowercased() } + command.aliases
        if haystacks.contains(where: { $0.contains(query) }) { return Match(command: command, score: 400, highlights: []) }
        var highlights: [Int] = []
        var remaining = query[...]
        for (index, character) in characters.enumerated() where character == remaining.first {
            highlights.append(index)
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return Match(command: command, score: 100 - name.count, highlights: highlights) }
        }
        return nil
    }

    /// Matches in rank order; without a query the catalog order is kept.
    static func filter(_ commands: [AskCommand], query: String) -> [Match] {
        let matches = commands.compactMap { match($0, query: query) }
        guard !query.isEmpty else { return matches }
        var seen = Set<String>()
        return matches.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
            .filter { seen.insert($0.command.name).inserted }
    }
}

/// The palette's navigation: the visible rows, the highlighted one and the
/// submenu it is in. Disabled rows are skipped by the arrow keys.
struct AskCommandPaletteState: Equatable {
    var query = ""
    /// The submenu command, when one is open.
    var parent: AskCommand?
    var rows: [AskCommandMatcher.Match] = []
    var highlighted = 0

    var highlightedCommand: AskCommand? { rows.indices.contains(highlighted) ? rows[highlighted].command : nil }

    /// A new query puts the best match first under the highlight; the same query
    /// (a refresh) keeps the highlighted row where it is.
    mutating func update(rows: [AskCommandMatcher.Match], query: String? = nil, parent: AskCommand? = nil) {
        let previous = highlightedCommand?.id
        let sameList = (query ?? self.query) == self.query && parent?.id == self.parent?.id
        self.rows = rows
        if let query { self.query = query }
        self.parent = parent
        highlighted = sameList ? previous.flatMap { id in rows.firstIndex { $0.command.id == id } } ?? 0 : 0
        if !(highlightedCommand?.enabled ?? true) { move(1) }
    }

    /// Moves the highlight, wrapping at both ends and skipping disabled rows.
    mutating func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var index = highlighted
        for _ in 0 ..< rows.count {
            index = ((index + delta) % rows.count + rows.count) % rows.count
            if rows[index].command.enabled { highlighted = index; return }
        }
    }
}

/// The slash token the caret is in: "/mo" while choosing a command, "/model gpt"
/// while filtering a submenu, "/remember milk" while typing an argument. A slash
/// counts only at the start of the text or after whitespace, so paths such as
/// "a/b" never open the palette. "、" counts too: Chinese input methods type it
/// on the slash key.
struct AskSlashQuery: Equatable {
    /// UTF-16 range from the slash to the caret.
    var range: NSRange
    var name: String
    /// Text after "name "; nil until a space follows the name.
    var argument: String?

    /// "/" or the "、" a Chinese input method types on the slash key.
    private static let pattern = try! NSRegularExpression(pattern: #"(?:^|(?<=\s))[/、]([^\s/、]*)(?: ([^\n]*))?\z"#)

    static func parse(_ text: String, caret: Int) -> AskSlashQuery? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return nil }
        let before = string.substring(to: caret)
        let whole = NSRange(location: 0, length: (before as NSString).length)
        guard let match = pattern.firstMatch(in: before, range: whole) else { return nil }
        let name = (before as NSString).substring(with: match.range(at: 1))
        let argumentRange = match.range(at: 2)
        let argument = argumentRange.location == NSNotFound ? nil : (before as NSString).substring(with: argumentRange)
        return AskSlashQuery(range: match.range, name: name, argument: argument)
    }

    /// `text` with this token replaced.
    func replacing(in text: String, with replacement: String) -> String {
        let string = text as NSString
        guard NSMaxRange(range) <= string.length else { return text }
        return string.replacingCharacters(in: range, with: replacement)
    }
}

/// Keys the command palette takes from the editor while it is open.
enum AskCommandKey: Equatable {
    case up, down, enter, tab, escape
    case number(Int)
    /// ⌘Return: send to the AI whatever the launcher offers.
    case commandEnter
    /// Keys a keyword plugin's result answers to: ⌥Return writes it back,
    /// ⇧Tab steps an option back, ⌘R runs again, ⌘D compares with the original,
    /// ⌘C copies (the editor only offers it when it has nothing selected), ⇧⌘C copies all of a word card.
    case optionEnter, shiftTab, commandR, commandD, commandC, shiftCommandC
    /// ⌘E: edit the workflow that produced the result.
    case commandE
    /// ⌘Z: undo a workflow's copy; otherwise the editor's own undo.
    case commandZ
    /// ⌘S: star the word a translation looked up.
    case commandS
    /// ⌘B: open the word book from a translation.
    case commandB
    /// Keys for a found file or application: → opens its actions (the editor only offers it
    /// with the caret at the end), ⌘Y Quick Look, ⌥⌘C copies the file, ⇧⌘Return asks the AI
    /// about it, ⌘↓ shows all the files.
    case right, commandY, optionCommandC, shiftCommandEnter, commandDown

    init?(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if let number = AskLauncherNumberShortcuts.number(keyCode: event.keyCode, modifiers: modifiers,
                                                        characters: event.charactersIgnoringModifiers) {
            self = .number(number)
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if modifiers == .command, isReturn { self = .commandEnter; return }
        if modifiers == [.command, .shift], isReturn { self = .shiftCommandEnter; return }
        if modifiers == .command, event.keyCode == 16 { self = .commandY; return }
        if modifiers == .command, event.keyCode == 125 { self = .commandDown; return }
        if modifiers == [.command, .option], event.keyCode == 8 { self = .optionCommandC; return }
        if modifiers == .option, isReturn { self = .optionEnter; return }
        if modifiers == .shift, event.keyCode == 48 { self = .shiftTab; return }
        if modifiers == .command, event.keyCode == 15 { self = .commandR; return }
        if modifiers == .command, event.keyCode == 2 { self = .commandD; return }
        if modifiers == .command, event.keyCode == 14 { self = .commandE; return }
        if modifiers == .command, event.keyCode == 6 { self = .commandZ; return }
        if modifiers == .command, event.keyCode == 1 { self = .commandS; return }
        if modifiers == .command, event.keyCode == 11 { self = .commandB; return }
        if modifiers == .command, event.keyCode == 8 { self = .commandC; return }
        if modifiers == [.command, .shift], event.keyCode == 8 { self = .shiftCommandC; return }
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 126: self = .up
        case 125: self = .down
        case 36, 76: self = .enter
        case 48: self = .tab
        case 53: self = .escape
        case 124: self = .right
        default: return nil
        }
    }
}
