import Foundation

enum TerminalApplication: String, CaseIterable, Sendable {
    case terminal, iterm

    var title: String {
        self == .terminal ? "Terminal" : "iTerm2"
    }

    var bundleID: String {
        self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2"
    }

    static func configured(in options: [String: String]) -> Self? {
        guard let value = options[AskTerminalCommandPlugin.terminalOption] else { return .terminal }
        return Self(rawValue: value)
    }
}

struct TerminalCommandRequest: Equatable, Sendable {
    var command: String
    /// The external terminal app, which also offers to run a built-in command again.
    var terminal: TerminalApplication
    /// Set to run the command in Typeflux's own terminal window instead of `terminal`.
    var builtin: TerminalRunSettings?

    init(command: String, terminal: TerminalApplication, builtin: TerminalRunSettings? = nil) {
        self.command = command
        self.terminal = terminal
        self.builtin = builtin
    }

    var runner: TerminalRunner {
        builtin == nil ? .external : .builtin
    }

    static let maximumBytes = 16 * 1024

    static func problem(with command: String) -> String? {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("terminal.command.empty")
        }
        if command.utf8.count > maximumBytes {
            return L("terminal.command.tooLarge")
        }
        if command.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) {
            return L("terminal.command.singleLine")
        }
        return nil
    }
}

/// Planning never executes a command. Only the launcher's explicit submit action
/// can hand the immutable request to the built-in terminal or the terminal dispatcher.
struct AskTerminalCommandPlugin: AskLauncherPlugin {
    static let id = "terminalCommand"
    static let terminalOption = "terminal"
    static let keywords = [AskKeyword(keyword: "cmd", pluginID: id, aliases: [">"])]

    static func conflicts(in keywords: [AskKeyword], workflows: [AskWorkflowKeywordEntry]) -> [String] {
        Self.keywords[0].allKeywords.filter { word in
            keywords.contains { $0.pluginID != id && $0.contains(word) }
                || workflows.contains { $0.keyword.caseInsensitiveCompare(word) == .orderedSame }
        }
    }

    var id: String {
        Self.id
    }

    var title: String {
        L("terminal.command.title")
    }

    var symbol: String {
        "terminal"
    }

    var defaultKeywords: [AskKeyword] {
        Self.keywords
    }

    var usesSelectionInput: Bool {
        false
    }

    var entersOnReturn: Bool {
        true
    }

    var preservesInputWhitespace: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        L("terminal.command.placeholder")
    }

    func inputChipTitle(for keyword: AskKeyword) -> String {
        keyword.keyword
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let problem = TerminalCommandRequest.problem(with: request.text)
        guard problem == nil, let terminal = TerminalApplication.configured(in: request.options) else {
            return .init(mode: .onSubmit, title: problem ?? L("terminal.command.invalidTerminal"))
        }
        let runner = TerminalRunSettings.runner(in: request.options)
        let settings = TerminalRunSettings(options: request.options)
        func command(_ runner: TerminalRunner) -> TerminalCommandRequest {
            .init(command: request.text, terminal: terminal, builtin: runner == .builtin ? settings : nil)
        }
        func title(_ runner: TerminalRunner) -> String {
            runner == .builtin ? L("terminal.runner.runBuiltin") : L("terminal.command.runIn", terminal.title)
        }
        let detail = runner == .builtin
            ? L("terminal.runner.planDetail", settings.directory,
                settings.shell == .interactive ? L("terminal.runner.shell.interactive")
                    : L("terminal.runner.shell.login"))
            : L("terminal.command.directory")
        return .init(mode: .onSubmit, title: title(runner),
                     meta: [.init(text: request.text), .init(text: detail)],
                     actions: [
                         .init(kind: .terminalCommand(command(runner)), title: L("terminal.command.run"),
                               symbol: "terminal", shortcut: .enter),
                         .init(kind: .terminalCommand(command(runner.other)), title: title(runner.other),
                               symbol: runner.other == .builtin ? "terminal" : "arrow.up.forward.app",
                               shortcut: .commandEnter),
                         .init(kind: .copy(request.text), title: L("terminal.command.copy"),
                               symbol: "doc.on.doc", shortcut: .commandC),
                         .init(kind: .terminalAutomationSettings, title: L("ask.browser.automationSettings"),
                               symbol: "lock.shield", shortcut: .optionEnter)
                     ])
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        // Hotkeys, workflow chains, reruns and pending plans cannot dispatch.
        throw AskPluginFailure(message: TerminalCommandRequest.problem(with: request.text)
            ?? L("terminal.command.pressReturn"), retry: false)
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }
}
