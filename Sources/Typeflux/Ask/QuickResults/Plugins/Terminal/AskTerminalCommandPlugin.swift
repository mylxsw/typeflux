import Foundation
import SwiftUI

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
    /// Settings for Typeflux-hosted sessions. An external terminal runs with its own settings.
    var builtin: TerminalRunSettings?
    var destination: TerminalRunner

    init(command: String, terminal: TerminalApplication, builtin: TerminalRunSettings? = nil,
         destination: TerminalRunner? = nil) {
        self.command = command
        self.terminal = terminal
        self.builtin = builtin
        self.destination = destination ?? (builtin == nil ? .external : .window)
    }

    var runner: TerminalRunner {
        destination
    }

    static let maximumBytes = 16 * 1024

    static func problem(with command: String) -> String? {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("terminal.command.empty")
        }
        return lineProblem(command)
    }

    static func lineProblem(_ line: String) -> String? {
        if line.utf8.count > maximumBytes {
            return L("terminal.command.tooLarge")
        }
        if line.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) {
            return L("terminal.command.singleLine")
        }
        return nil
    }

    static func configured(command: String, options: [String: String], destination: TerminalRunner) -> Self? {
        guard problem(with: command) == nil,
              let target = TerminalApplication.configured(in: options) else { return nil }
        return .init(command: command, terminal: target,
                     builtin: destination == .external ? nil : TerminalRunSettings(options: options),
                     destination: destination)
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

    var keywordColor: Color { .green }

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

    func inputChipTitle(for _: AskKeyword) -> String {
        L("terminal.launcher.label")
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let problem = TerminalCommandRequest.problem(with: request.text)
        guard let externalRequest = TerminalCommandRequest.configured(
            command: request.text, options: request.options, destination: .external
        ) else {
            return .init(mode: .onSubmit, title: problem ?? L("terminal.command.invalidTerminal"))
        }
        let runner = TerminalRunSettings.runner(in: request.options)
        let settings = TerminalRunSettings(options: request.options)
        func action(_ destination: TerminalRunner, _ shortcut: AskPluginAction.Shortcut, title: String) -> AskPluginAction {
            var command = externalRequest
            command.destination = destination
            command.builtin = destination == .external ? nil : settings
            return .init(kind: .terminalCommand(command), title: title,
                         symbol: destination == .external ? "arrow.up.forward.app" : "terminal",
                         shortcut: shortcut)
        }
        let external = L("terminal.command.runIn", externalRequest.terminal.title)
        let alternate = TerminalRunSettings.alternateRunner(in: request.options)
        let alternateTitle = L(alternate == .window ? "terminal.launcher.window" : "terminal.launcher.runInLauncher")
        return .init(mode: .onSubmit, title: request.text,
                     meta: [.init(text: settings.directory)],
                     actions: [
                         action(runner, .enter, title: request.text),
                         action(alternate, .commandEnter, title: alternateTitle),
                         action(.external, .optionEnter, title: external),
                         .init(kind: .copy(request.text), title: L("terminal.command.copy"),
                               symbol: "doc.on.doc", shortcut: .commandC)
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
