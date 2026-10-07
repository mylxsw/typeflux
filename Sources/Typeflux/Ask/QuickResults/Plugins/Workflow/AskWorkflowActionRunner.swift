import Foundation

/// What an `open` action opens once its placeholders are filled in.
enum AskWorkflowOpenTarget: Equatable, Sendable {
    /// An http(s) link.
    case link(URL)
    case file(URL)
    /// An application by name ("Notes") or bundle id ("com.apple.Notes").
    case application(String)
}

/// An action with its placeholders filled in, ready to run.
enum AskWorkflowEffect: Equatable, Sendable {
    case copy(String)
    case writeBack(String)
    case notify(title: String, body: String)
    case hud(String)
    case open(AskWorkflowOpenTarget)
    case reveal(URL)
    case speak(String, language: String?)
    case askAI(String)
    /// Puts `keyword argument` in the launcher and runs it. `chain` is every keyword in
    /// this chain so far, this run's last, for the next run to carry on.
    case runKeyword(String, argument: String, chain: [String])

    /// Affects another app or leaves the launcher: a test run asks before it does it.
    var needsConfirmationInTest: Bool {
        switch self {
        case .writeBack, .open, .runKeyword: true
        default: false
        }
    }

    /// Leaves the launcher: what runs after it no longer has a bottom bar.
    var closesLauncher: Bool {
        switch self {
        case .writeBack, .open, .askAI: true
        default: false
        }
    }
}

/// One configured action for one run: the effect it will have, or why it cannot run.
struct AskWorkflowActionStep: Equatable, Sendable {
    var action: AskWorkflowAction
    var effect: AskWorkflowEffect?
    /// Why the action cannot run (an unknown action, a link that is not one, nothing to copy).
    var problem: String?
    /// The filled-in value to show: what is copied, the notification's text, the link.
    var detail: String
    /// `{json.…}` placeholders that found nothing in this output.
    var missing: [String] = []
    /// The script added it (`AskWorkflowScriptOutput`) rather than the manifest.
    var fromScript = false
    /// Listed but never run, and why: script actions the manifest does not allow.
    var notRun: String?
    /// A web host the workflow does not name anywhere: the user allows it first.
    var confirmHost: String?

    var title: String {
        action.kind?.title ?? action.action
    }

    var symbol: String {
        action.kind?.symbol ?? "questionmark.circle"
    }
}

/// Where a step ended.
struct AskWorkflowActionOutcome: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case done
        /// Done another way, such as a bottom-bar note when notifications are not allowed.
        case fellBack(String)
        case failed(String)
        /// Listed, not run (the test panel's "preview only", or the user said no).
        case skipped(String?)
    }

    var step: AskWorkflowActionStep
    var status: Status

    var succeeded: Bool {
        switch status {
        case .done, .fellBack: true
        case .failed, .skipped: false
        }
    }
}

/// The actions to take after one run, and whether the launcher closes when they are done.
struct AskWorkflowFollowUp: Equatable, Sendable {
    /// Tells this run's actions from the next one's, so they run once.
    var id = UUID()
    var steps: [AskWorkflowActionStep]
    var closes: Bool
}

/// Does what an effect says; the launcher and the editor's test panel each provide one.
@MainActor
protocol AskWorkflowActionHost: AnyObject {
    func copy(_ text: String)
    func writeBack(_ text: String)
    /// False when notifications are not allowed (or failed): the runner falls back to `hud`.
    func notify(title: String, body: String) async -> Bool
    func hud(_ text: String)
    /// False when there was nothing to open.
    func open(_ target: AskWorkflowOpenTarget) -> Bool
    func reveal(_ url: URL) -> Bool
    func speak(_ text: String, language: String?)
    func askAI(_ prompt: String)
    /// False when there is no such keyword, or nowhere to run it.
    func runKeyword(_ keyword: String, argument: String, chain: [String]) -> Bool
    /// Whether this workflow may open `host`, which it does not name itself; asked once
    /// and remembered per workflow. False when the user says no or cannot be asked.
    func approve(host: String) async -> Bool
}

/// Fills in a workflow's actions and runs them in order. One that fails does not
/// stop the ones after it. See `docs/design/workflow-gallery-output-actions.md` §3.3.
enum AskWorkflowActionRunner {
    /// Each action with its placeholders filled in, in the configured order. `chain`
    /// is the keywords that led to this run, this run's last (`runKeyword` refuses loops).
    static func steps(for actions: [AskWorkflowAction], placeholders: AskWorkflowPlaceholders, folder: URL,
                      name: String, home: String = NSHomeDirectory(), chain: [String] = [],
                      fileManager: FileManager = .default) -> [AskWorkflowActionStep] {
        actions.prefix(AskWorkflowManifest.Output.maximumActions).map { action in
            step(for: action, placeholders: placeholders, folder: folder, name: name, home: home, chain: chain,
                 fileManager: fileManager)
        }
    }

    /// The actions a script printed, after the configured ones. Their values are used
    /// as written (no placeholders). Without `allowed` they are only listed. A web link
    /// to a host the workflow does not name is asked about before it opens.
    static func scriptSteps(_ actions: [AskWorkflowAction], allowed: Bool, folder: URL, name: String,
                            home: String = NSHomeDirectory(), chain: [String] = [],
                            knownHosts: () -> Set<String>,
                            fileManager: FileManager = .default) -> [AskWorkflowActionStep] {
        var known: Set<String>?
        return actions.prefix(AskWorkflowManifest.Output.maximumActions).map { action in
            var step = step(for: action, placeholders: AskWorkflowPlaceholders(output: ""), folder: folder,
                            name: name, home: home, chain: chain, expands: false, fileManager: fileManager)
            step.fromScript = true
            if !allowed {
                step.notRun = L("ask.workflow.action.scriptNotAllowed")
            } else if case let .open(.link(url)) = step.effect, let host = AskWorkflowScriptOutput.host(of: url) {
                // Read the folder only when a link needs it, and once per run.
                let names = known ?? knownHosts()
                known = names
                if !isKnown(host, in: names) {
                    step.confirmHost = host
                }
            }
            return step
        }
    }

    /// `host` is one of `known`, or under one (`www.xe.com` under `xe.com`).
    static func isKnown(_ host: String, in known: Set<String>) -> Bool {
        known.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // One case per kind of action; splitting it would only scatter them.
    // swiftlint:disable:next cyclomatic_complexity
    static func step(for action: AskWorkflowAction, placeholders: AskWorkflowPlaceholders, folder: URL, name: String,
                     home: String = NSHomeDirectory(), chain: [String] = [], expands: Bool = true,
                     fileManager: FileManager = .default) -> AskWorkflowActionStep {
        var step = AskWorkflowActionStep(action: action, detail: "")
        guard let kind = action.kind else {
            step.problem = L("ask.workflow.problem.action.unknown", action.action)
            return step
        }
        func fill(_ field: AskWorkflowAction.Field, urlEncoded: Bool = false) -> String {
            let template = action[field] ?? ""
            guard expands else { return template.trimmingCharacters(in: .whitespacesAndNewlines) }
            step.missing += placeholders.missingJSON(in: template)
            return placeholders.expand(template, urlEncoded: urlEncoded).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let required = fill(kind.requiredField, urlEncoded: kind == .open)
        step.detail = required
        guard !required.isEmpty else {
            step.problem = L("ask.workflow.action.empty")
            return step
        }
        switch kind {
        case .copy: step.effect = .copy(required)
        case .writeBack: step.effect = .writeBack(required)
        case .hud: step.effect = .hud(required)
        case .askAI: step.effect = .askAI(required)
        case .notify:
            let title = fill(.title)
            step.effect = .notify(title: title.isEmpty ? name : title, body: required)
            step.detail = (title.isEmpty ? name : title) + " · " + required
        case .speak:
            let language = fill(.language)
            step.effect = .speak(required, language: language.isEmpty ? nil : language)
        case .open:
            if let target = openTarget(required, folder: folder, home: home, fileManager: fileManager) {
                step.effect = .open(target)
            } else {
                step.problem = L("ask.workflow.action.cannotOpen", required)
            }
        case .reveal:
            if let url = file(required, folder: folder, home: home), fileManager.fileExists(atPath: url.path) {
                step.effect = .reveal(url)
            } else {
                step.problem = L("ask.workflow.action.notFound", required)
            }
        case .runKeyword:
            let argument = fill(.argument)
            step.detail = argument.isEmpty ? required : required + " " + argument
            step.problem = chainProblem(required, chain: chain)
            if step.problem == nil {
                step.effect = .runKeyword(required, argument: argument, chain: chain)
            }
        }
        return step
    }

    /// Why `keyword` cannot run after `chain`: not one word, already in the chain (a
    /// loop), or one run too many.
    static func chainProblem(_ keyword: String, chain: [String]) -> String? {
        guard AskWorkflowAction.isKeyword(template: keyword), !keyword.hasPrefix("{") else {
            return L("ask.workflow.problem.action.keyword")
        }
        if chain.contains(where: { $0.lowercased() == keyword.lowercased() }) {
            return L("ask.workflow.action.loop", (chain + [keyword]).joined(separator: " → "))
        }
        if chain.count > AskWorkflowAction.maximumChain {
            return L("ask.workflow.action.tooDeep", AskWorkflowAction.maximumChain)
        }
        return nil
    }

    /// An http(s) link, `app:` and a name or bundle id, or an existing file. Other
    /// schemes (`javascript:`, `ssh:`) are never opened.
    static func openTarget(_ text: String, folder: URL, home: String,
                           fileManager: FileManager = .default) -> AskWorkflowOpenTarget? {
        switch AskWorkflowAction.scheme(of: text) {
        case "http", "https":
            guard let url = URL(string: text), url.host?.isEmpty == false else { return nil }
            return .link(url)
        case "app":
            let name = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .application(name)
        case "file":
            guard let url = URL(string: text), url.isFileURL,
                  fileManager.fileExists(atPath: url.path) else { return nil }
            return .file(url)
        case nil:
            guard let url = file(text, folder: folder, home: home), fileManager.fileExists(atPath: url.path) else {
                return nil
            }
            return .file(url)
        default:
            return nil
        }
    }

    /// A path as a file: `~/…` under the home folder, absolute as written, anything
    /// else inside the workflow's folder (never outside it).
    static func file(_ path: String, folder: URL, home: String) -> URL? {
        if path == "~" {
            return URL(fileURLWithPath: home)
        }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: home).appendingPathComponent(String(path.dropFirst(2)))
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return AskWorkflowManifest.scriptURL(path, in: folder)
    }

    /// Runs the steps in order. With `perform` false nothing runs and every step is
    /// listed as previewed. `confirm` makes it a test run: it is asked before a step
    /// that needs it (writeBack, open, runKeyword), answering no skips that step only,
    /// and `askAI` is not run. Script actions that are not allowed are never run; a
    /// link to a host the workflow does not name runs once the host approves it.
    @MainActor
    static func run(_ steps: [AskWorkflowActionStep], host: any AskWorkflowActionHost, perform: Bool = true,
                    confirm: ((AskWorkflowActionStep) async -> Bool)? = nil) async -> [AskWorkflowActionOutcome] {
        var outcomes: [AskWorkflowActionOutcome] = []
        for step in steps {
            outcomes.append(await run(step, host: host, perform: perform, confirm: confirm))
        }
        return outcomes
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private static func run(_ step: AskWorkflowActionStep, host: any AskWorkflowActionHost, perform: Bool,
                            confirm: ((AskWorkflowActionStep) async -> Bool)?) async -> AskWorkflowActionOutcome {
        if let reason = step.notRun {
            return AskWorkflowActionOutcome(step: step, status: .skipped(reason))
        }
        guard let effect = step.effect else {
            return AskWorkflowActionOutcome(step: step, status: .failed(step.problem ?? ""))
        }
        guard perform else { return AskWorkflowActionOutcome(step: step, status: .skipped(nil)) }
        // A test run (it confirms) does not hand the editor's result to a conversation.
        if confirm != nil, case .askAI = effect {
            return AskWorkflowActionOutcome(step: step, status: .skipped(L("ask.workflow.action.notInTest")))
        }
        if effect.needsConfirmationInTest, let confirm, !(await confirm(step)) {
            return AskWorkflowActionOutcome(step: step, status: .skipped(L("ask.workflow.action.declined")))
        }
        // A test run's question above already covered the link; the launcher asks the host.
        if confirm == nil, let unknown = step.confirmHost, !(await host.approve(host: unknown)) {
            return AskWorkflowActionOutcome(step: step, status: .skipped(L("ask.workflow.action.hostDeclined",
                                                                           unknown)))
        }
        switch effect {
        case let .copy(text): host.copy(text)
        case let .writeBack(text): host.writeBack(text)
        case let .hud(text): host.hud(text)
        case let .askAI(prompt): host.askAI(prompt)
        case let .speak(text, language): host.speak(text, language: language)
        case let .notify(title, body):
            guard await host.notify(title: title, body: body) else {
                host.hud(title + " · " + body)
                return AskWorkflowActionOutcome(step: step, status: .fellBack(L("ask.workflow.action.notifyDenied")))
            }
        case let .open(target):
            guard host.open(target) else {
                return AskWorkflowActionOutcome(step: step, status: .failed(L("ask.workflow.action.cannotOpen",
                                                                              step.detail)))
            }
        case let .reveal(url):
            guard host.reveal(url) else {
                return AskWorkflowActionOutcome(
                    step: step,
                    status: .failed(L("ask.workflow.action.notFound", url.path))
                )
            }
        case let .runKeyword(keyword, argument, chain):
            guard host.runKeyword(keyword, argument: argument, chain: chain) else {
                return AskWorkflowActionOutcome(step: step, status: .failed(L("ask.workflow.action.noKeyword",
                                                                              keyword)))
            }
        }
        return AskWorkflowActionOutcome(step: step, status: .done)
    }

    // MARK: - Summary

    /// The launcher's bottom bar after the actions ran: "✓ Copied “…” · ✓ Notification sent".
    static func summary(_ outcomes: [AskWorkflowActionOutcome]) -> String {
        outcomes.compactMap { outcome -> String? in
            switch outcome.status {
            case .done: "✓ " + doneText(outcome.step)
            // Say what was shown instead, not that the notification went out.
            case let .fellBack(reason): "✓ " + clipped(outcome.step.detail, limit: 60) + " (" + reason + ")"
            case let .failed(reason): "✕ " + outcome.step.title + (reason.isEmpty ? "" : ": " + reason)
            case .skipped: nil
            }
        }.joined(separator: " · ")
    }

    /// "Copied “100 USD = 14,912.30 JPY”", "Notification sent".
    static func doneText(_ step: AskWorkflowActionStep) -> String {
        guard let kind = step.action.kind else { return step.title }
        switch kind {
        case .copy: return L("ask.workflow.action.done.copy", clipped(step.detail))
        // The note itself is what the bar shows.
        case .hud: return clipped(step.detail, limit: 60)
        case .runKeyword: return L("ask.workflow.action.done.runKeyword", clipped(step.detail))
        default: return L("ask.workflow.action.done." + kind.rawValue)
        }
    }

    /// The first line, cut to `limit` characters, for one-line summaries.
    static func clipped(_ text: String, limit: Int = 40) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let cut = line.count > limit ? String(line.prefix(limit)) + "…" : line
        return text.contains("\n") && line.count <= limit ? cut + "…" : cut
    }
}
