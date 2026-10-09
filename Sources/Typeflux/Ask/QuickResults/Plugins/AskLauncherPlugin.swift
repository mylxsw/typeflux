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
    /// Whether captured text may supply the argument when the editor is empty.
    var usesSelectionInput: Bool { get }
    /// A lone keyword defaults to entering its local feature on Return.
    var entersOnReturn: Bool { get }
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
    var usesSelectionInput: Bool { true }
    var entersOnReturn: Bool { false }
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
    /// The keywords whose workflows started this run with `runKeyword`, first one
    /// first; empty when the user started it. Stops loops and deep chains.
    var chain: [String] = []

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
    /// How long a live plan waits after the last keystroke; nil for the session's default.
    var debounce: Duration?

    func action(for shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        actions.first { $0.shortcut == shortcut }
    }
}

/// Something done with a result. The same key means the same thing in every plugin.
struct AskPluginAction: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case openChat
        case openSettings
        case openConversation(String, account: String)
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
        /// Opens a file or folder in an application (by name or bundle id), like a project in an editor.
        case openIn(URL, application: String)
        /// Shows a file in Finder.
        case reveal(URL)
        /// Puts an image file on the clipboard, as an image.
        case copyImage(URL)
        /// Puts this text after the keyword and runs again: ⇥ on an item, or its `run` action.
        case runWith(String)
        /// Enters another keyword and waits for input, without carrying the directory query.
        case enterKeyword(String)
        /// Opens a workflow in the workflow editor, at a line of a file when known.
        case editWorkflow(id: String, path: String?, line: Int?)
        /// Opens the workflow editor and asks its assistant to fix what failed.
        case fixWorkflow(id: String, query: String, error: String)
        /// Stars or unstars a looked-up word in the word book (⌘S).
        case toggleStar(AskWordBookLookup)
        /// Opens the word book dialog, on this word when there is one (⌘B).
        case openWordBook(key: String?)
        /// Opens the word book and looks this word up there (`dict`).
        case lookUpInWordBook(String)
        /// Copies Markdown as rich text (HTML and RTF, with the source as plain text) and stays (⇧⌘C).
        case copyRich(String)
        /// Moves the result, even one still streaming, into a window of its own (⌘O).
        case openInWindow
        /// Saves the result to the notes, or takes it out again (⌘S).
        case toggleNote(AskNoteDraft)
        /// Opens the notes window, on this note when there is one (⌘B).
        case openNotes(id: UUID?)
        /// Opens a saved note in a result window (`nb` keyword).
        case openNote(UUID)
    }

    enum Shortcut: Equatable, Sendable {
        case enter, optionEnter, commandR, commandD, commandC, shiftCommandC, commandE, commandS, commandB, commandO
    }

    var kind: Kind
    var title: String
    var symbol: String
    var shortcut: Shortcut?
}

/// One row of a result list (a workflow's `{"items": …}`), with what its keys do.
struct AskPluginItem: Equatable, Sendable, Identifiable {
    enum Icon: Equatable, Sendable {
        case symbol(String)
        case image(URL)
        /// The Finder icon of a file or folder.
        case fileIcon(URL)
        /// The icon of a type, such as `public.folder`.
        case fileType(String)
    }

    var id: String
    var title: String
    var subtitle = ""
    var icon: Icon?
    /// False: shown, never acted on.
    var valid = true
    /// What ⇥ completes to.
    var autocomplete: String?
    /// Return, ⌥↩ and ⌘C for this row, and asking the AI about it.
    var actions: [AskPluginAction] = []
}

/// An image to show as a result: a file on this Mac and its size in points.
struct AskPluginImage: Equatable, Sendable {
    var url: URL
    var width: Double
    var height: Double
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
    /// What a workflow does after the run: copy, notify, open… (`AskWorkflowActionRunner`).
    var followUp: AskWorkflowFollowUp?
    /// `body` is Markdown, drawn as Ask draws answers.
    var markdown = false
    /// An image shown in place of `body`, which then holds what the script printed (its path).
    var image: AskPluginImage?
    /// A list to choose from instead of text; `body` then holds the titles.
    var items: [AskPluginItem] = []
    /// The chosen row; the arrows move it.
    var selectedItem = 0
    /// Run again after this many seconds while the result is shown.
    var rerunAfter: Double?
    /// Options for the next run (a workflow's `variables`).
    var variables: [String: String] = [:]
    /// A word or phrase the translation plugin looked up, for the word book.
    var wordBook: AskWordBookLookup?
    /// The lookup goes into the word book as soon as it shows (the user pressed Return
    /// for it); otherwise only once it settles: used, or shown a while (`AskPluginSession`).
    var recordsAtOnce = false
    /// Whether the looked-up word is starred; nil when it cannot be.
    var starred: Bool?
    /// A short fact beside the source, such as how often the word was looked up.
    var detail: String?

    var selected: AskPluginItem? {
        items.indices.contains(selectedItem) ? items[selectedItem] : nil
    }

    /// What a key does. With a list it is the chosen row's (Return, ⌥↩, ⌘C), and
    /// the result's for the rest (⌘R, ⌘E).
    func action(for shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        if !items.isEmpty {
            if let action = selected?.actions.first(where: { $0.shortcut == shortcut }) { return action }
            return [.enter, .optionEnter, .commandC].contains(shortcut) ? nil
                : actions.first { $0.shortcut == shortcut }
        }
        return actions.first { $0.shortcut == shortcut }
            // ⌘C copies the result without closing, unless the plugin says otherwise.
            ?? (shortcut == .commandC ? AskPluginAction(kind: .copy(body), title: L("ask.plugin.action.copy"),
                                                        symbol: "doc.on.doc", shortcut: .commandC) : nil)
    }

    /// What ⌘↩ asks the AI: about the chosen row, or the whole result.
    var askAIAction: AskPluginAction? {
        let isAsk: (AskPluginAction) -> Bool = { if case .askAI = $0.kind { true } else { false } }
        return selected?.actions.first(where: isAsk) ?? actions.first(where: isAsk)
    }
}

/// A failure to show in the card, with what can be done about it.
struct AskPluginFailure: Error, Equatable, Sendable {
    var message: String
    var retry: Bool = true
    /// What the failure card offers besides retrying, such as editing the workflow.
    var actions: [AskPluginAction] = []
    /// What a workflow does after a failed run, such as a notification.
    var followUp: AskWorkflowFollowUp?

    func action(for shortcut: AskPluginAction.Shortcut) -> AskPluginAction? {
        actions.first { $0.shortcut == shortcut }
    }
}
