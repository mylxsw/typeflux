import Foundation

/// A capability the launcher runs on a piece of text, reached by keywords.
/// The launcher owns the interface, keys and states; a plugin only says what
/// it works on, when it runs and what it produces.
protocol AskLauncherPlugin: Sendable {
    var id: String { get }
    var title: String { get }
    /// SF Symbol for the keyword chip and the result card.
    var symbol: String { get }
    var defaultKeywords: [AskKeyword] { get }
    /// What ⇥ changes, for the bottom bar ("Language"); nil when it changes nothing.
    var optionName: String? { get }
    /// Runs with nothing typed and nothing selected, like a workflow that shows the IP address.
    var runsWithoutInput: Bool { get }
    /// What the editor says while the keyword is active.
    func placeholder(selectionLines: Int?) -> String
    /// A keyword's preset for its chip, e.g. "Japanese" for `fyja`; nil for none.
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String?
    /// What running `request` will do, and whether it may run while typing.
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan
    /// Runs the request. Plugins that produce text gradually report each step to
    /// `progress`, which the launcher shows while the run goes on.
    func run(_ request: AskPluginRequest, plan: AskPluginPlan, progress: @escaping AskPluginProgress) async throws -> AskPluginOutput
    /// The option ⇥ moves to: the next target language, say. Nil when there is none.
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]?
}

extension AskLauncherPlugin {
    var optionName: String? { nil }
    var runsWithoutInput: Bool { false }
}

/// Receives a result as it grows, on the main actor and in order.
typealias AskPluginProgress = @MainActor @Sendable (AskPluginOutput) -> Void

/// What a plugin is asked to work on.
struct AskPluginRequest: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Typed after the keyword.
        case argument
        /// The selection the launcher captured, used when nothing was typed.
        case selection
    }

    var text: String
    var origin: Origin
    var keyword: AskKeyword
    /// The keyword's presets with the user's changes in this launcher (⇥, ⌘R) on top.
    var options: [String: String]
    var interfaceLanguage: AppLanguage
    /// The captured selection, whichever text the request works on. Plugins only
    /// hand it on after Return, as they do the selection itself.
    var selection: String?

    /// Lines of selected text, for "translate the 2 selected lines".
    var lines: Int { text.split(separator: "\n", omittingEmptySubsequences: true).count }
}

/// A label on the result: "English → Simplified Chinese", an engine name.
struct AskPluginMeta: Equatable, Sendable {
    var text: String
    var emphasized = false
}

/// What a request will do before it runs.
struct AskPluginPlan: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Cheap and private: run while typing, after a short pause.
        case live
        /// Waits for Return: selected text, models, anything that leaves the Mac.
        case onSubmit
    }

    var mode: Mode
    /// "Translate the 2 selected lines".
    var title: String
    var meta: [AskPluginMeta] = []
    /// Plugin-specific details the run needs, such as the languages chosen.
    var values: [String: String] = [:]
    /// What the keys do before anything runs. A plan with a Return action (open a
    /// search) does that instead of running; ⌘C may copy something (its link).
    var actions: [AskPluginAction] = []

    func action(for shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        actions.first { $0.shortcut == shortcut }
    }
}

/// Something done with a result. The same key means the same thing in every plugin.
struct AskPluginAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case copy(String)
        /// Writes into the app the launcher came from, over its selection when there is one.
        case writeBack(String)
        case speak(String, language: String)
        /// Runs again with these options added, e.g. a different engine.
        case rerun([String: String])
        case compare
        case askAI(String)
        /// Opens a link, such as a web search, and closes the launcher.
        case open(URL)
    }

    enum Shortcut: Equatable, Sendable {
        case enter, optionEnter, commandR, commandD, commandC, shiftCommandC
    }

    var kind: Kind
    var title: String
    var symbol: String
    var shortcut: Shortcut?
}

/// A plugin's result, shown as a text card. Plugins that only act (open a search)
/// put their actions on the plan instead and never produce one.
struct AskPluginOutput: Equatable, Sendable {
    var body: String
    var original: String
    var meta: [AskPluginMeta]
    /// Where the result came from: "On this Mac", "AI · model".
    var source: String
    var sourceIsAI = false
    /// A line under the text, e.g. why the AI was used.
    var note: String?
    var actions: [AskPluginAction]
    /// A dictionary entry shown in place of `body`, which then holds its one-line summary.
    var wordCard: AskWordCard?
    /// The run did what it was for (a workflow that opens something): the launcher closes.
    var dismisses = false

    func action(for shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        actions.first { $0.shortcut == shortcut }
            // ⌘C copies the result without closing, unless the plugin says otherwise.
            ?? (shortcut == .commandC ? AskPluginAction(kind: .copy(body), title: L("ask.plugin.action.copy"),
                                                        symbol: "doc.on.doc", shortcut: .commandC) : nil)
    }
}

/// A failure to show in the card, with what can be done about it.
struct AskPluginFailure: Error, Equatable, Sendable {
    var message: String
    var retry: Bool = true
}
