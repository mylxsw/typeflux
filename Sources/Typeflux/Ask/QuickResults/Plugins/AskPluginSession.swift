import Foundation

/// The launcher's keyword mode: which keyword is active, what its plugin would
/// work on, and where its run stands. It publishes only real changes, so typing
/// does not re-render the launcher more than it must.
///
///     waiting ─text─▶ ready ─Return─▶ running ─▶ done / failed
///                       └── live plugins go straight to running
///     done ─edit─▶ the old result stays, dimmed, until the next one arrives
///     running ─progress─▶ the growing result (`partial`) replaces the dimmed one
@MainActor
final class AskPluginSession: ObservableObject {
    enum Phase: Equatable {
        /// Nothing to work on: no text after the keyword and no selection.
        case waiting
        /// Planned, waiting for Return.
        case ready(AskPluginPlan)
        case running(AskPluginPlan)
        case done(AskPluginPlan, AskPluginOutput)
        case failed(AskPluginPlan, AskPluginFailure)
    }

    /// Only the keyword was typed: offer it.
    @Published private(set) var hint: AskKeyword?
    /// The keyword shown as a chip; its text has left the editor.
    @Published private(set) var keyword: AskKeyword?
    @Published private(set) var phase: Phase = .waiting {
        didSet { if !isRunning { set(\.partial, nil) } }
    }
    /// The result so far while a streaming run goes on.
    @Published private(set) var partial: AskPluginOutput?
    /// The last result while a newer one is on its way, drawn dimmed.
    @Published private(set) var previous: AskPluginOutput?
    @Published private(set) var request: AskPluginRequest?
    /// ⌘D shows the original above the result.
    @Published var comparing = false

    private var plugins: [String: any AskLauncherPlugin]
    private var keywords: () -> [AskKeyword]
    private var overrides: [String: String] = [:]
    /// The request the shown plan was made for; the text may have moved on since.
    private var plannedFor: AskPluginRequest?
    /// Return came while the plan for the latest text was still being made.
    private var pendingRun = false
    private var generation = 0
    private var task: Task<Void, Never>?
    /// The keywords that led here with `runKeyword`, and the text the last one put in.
    private var chained: (keywords: [String], text: String)?
    /// How long a live plugin waits after the last keystroke.
    var debounce: Duration = .milliseconds(250)
    /// Keeps looked-up words in the word book; nil keeps nothing.
    var recordWordBook: (@MainActor (AskWordBookLookup) -> Void)?
    /// A new keyword mode began: the word book counts every word again.
    var beginWordBookSession: (@MainActor () -> Void)?
    /// A result shown this long counts as looked up when keyword mode ends.
    var settleDelay: TimeInterval = 1.5
    var clock: () -> Date = Date.init
    /// When the shown result arrived.
    private var shownAt: Date?

    init(plugins: [any AskLauncherPlugin], keywords: @escaping () -> [AskKeyword]) {
        self.plugins = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.keywords = keywords
    }

    /// Swaps in a new set of plugins (workflows were added or changed). A keyword
    /// whose plugin is gone leaves keyword mode.
    func replacePlugins(_ replacement: [any AskLauncherPlugin]) {
        plugins = Dictionary(replacement.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let keyword, plugins[keyword.pluginID] == nil { deactivate() }
        if let hint, plugins[hint.pluginID] == nil { set(\.hint, nil) }
    }

    var plugin: (any AskLauncherPlugin)? { keyword.flatMap(plugin(for:)) }
    func plugin(for keyword: AskKeyword) -> (any AskLauncherPlugin)? { plugins[keyword.pluginID] }
    var isActive: Bool { keyword != nil }
    var output: AskPluginOutput? { if case let .done(_, output) = phase { output } else { nil } }
    var isRunning: Bool { if case .running = phase { true } else { false } }

    /// Keywords whose plugin exists, for matching.
    var availableKeywords: [AskKeyword] { keywords().filter { plugins[$0.pluginID] != nil } }

    // MARK: - Keyword

    /// Looks for a keyword at the start of `text` while none is active. Returns
    /// the argument when one became active, so the editor keeps only that.
    func detect(in text: String) -> String? {
        guard keyword == nil else { return nil }
        switch AskKeywordMatcher.match(text, keywords: availableKeywords) {
        case let .active(found, argument):
            set(\.hint, nil)
            activate(found)
            return argument
        case let .hint(found):
            set(\.hint, found)
        case nil:
            set(\.hint, nil)
        }
        return nil
    }

    /// Enters the hinted keyword (⇥ on the hint).
    func acceptHint() -> Bool {
        guard let hint else { return false }
        set(\.hint, nil)
        activate(hint)
        return true
    }

    /// Enters a keyword chosen in the `/` palette, leaving any other first.
    func enter(_ chosen: AskKeyword) {
        guard plugin(for: chosen) != nil else { return }
        deactivate()
        set(\.hint, nil)
        activate(chosen)
    }

    private func activate(_ found: AskKeyword) {
        overrides = [:]
        chained = nil
        beginWordBookSession?()
        set(\.keyword, found)
        set(\.phase, .waiting)
    }

    /// Leaves keyword mode, returning the text to put back in the editor: the
    /// keyword (⌫ on an empty argument) or the keyword and its argument (closing).
    @discardableResult
    func deactivate(argument: String = "") -> String? {
        guard let keyword else { return nil }
        if let shownAt, clock().timeIntervalSince(shownAt) >= settleDelay { settleWordBook() }
        cancel()
        self.keyword = nil
        request = nil
        plannedFor = nil
        pendingRun = false
        previous = nil
        comparing = false
        overrides = [:]
        set(\.phase, .waiting)
        return argument.isEmpty ? keyword.keyword : keyword.keyword + " " + argument
    }

    // MARK: - Running

    /// Re-plans for the editor's text, or the selection when it is empty.
    /// `runWhenPlanned` runs even a Return-only plan at once (⇥ and ⌘R on a shown result).
    func update(text: String, selection: String?, language: AppLanguage, runWhenPlanned: Bool = false) {
        guard let keyword, let plugin else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selection?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? selection?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let options = keyword.options.merging(overrides) { $1 }
        var next: AskPluginRequest?
        if !trimmed.isEmpty {
            next = AskPluginRequest(text: trimmed, origin: .argument, keyword: keyword, options: options,
                                    interfaceLanguage: language, selection: selected)
        } else if let selected {
            next = AskPluginRequest(text: selected, origin: .selection, keyword: keyword, options: options,
                                    interfaceLanguage: language, selection: selected)
        } else if plugin.runsWithoutInput {
            next = AskPluginRequest(text: "", origin: .argument, keyword: keyword, options: options,
                                    interfaceLanguage: language)
        } else {
            next = nil
        }
        next?.chain = chain(for: trimmed)
        guard next != request else { return }
        request = next
        if let output { set(\.previous, output) }
        cancel()
        guard let next else { set(\.phase, .waiting); set(\.previous, nil); pendingRun = false; return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            let plan = await plugin.plan(next)
            guard let self, !Task.isCancelled, current == self.generation else { return }
            self.plannedFor = next
            let runNow = runWhenPlanned || self.pendingRun
            self.pendingRun = false
            if plan.mode == .live || runNow {
                self.set(\.phase, .running(plan))
                if plan.mode == .live, !runNow {
                    try? await Task.sleep(for: self.debounce)
                    guard !Task.isCancelled, current == self.generation else { return }
                }
                await self.execute(plan, request: next, generation: current, plugin: plugin)
            } else {
                self.set(\.phase, .ready(plan))
            }
        }
    }

    /// Return: runs a ready or failed request. False when there is nothing to run.
    @discardableResult
    func run() -> Bool {
        guard let request, let plugin else { return false }
        let plan: AskPluginPlan
        switch phase {
        case let .ready(ready): plan = ready
        case let .failed(failed, failure) where failure.retry: plan = failed
        default: return false
        }
        // The shown plan is for older text: run as soon as the current one is made.
        guard isPlanCurrent else { pendingRun = true; return true }
        cancel()
        generation += 1
        let current = generation
        set(\.phase, .running(plan))
        task = Task { [weak self] in
            await self?.execute(plan, request: request, generation: current, plugin: plugin)
        }
        return true
    }

    /// Runs again with options added: another target language (⇥), another engine (⌘R).
    /// A request waiting for Return keeps waiting; one that ran runs again.
    func rerun(with options: [String: String], selection: String?, text: String, language: AppLanguage) {
        let ranBefore: Bool
        switch phase {
        case .running, .done, .failed: ranBefore = true
        case .waiting, .ready: ranBefore = false
        }
        overrides.merge(options) { $1 }
        request = nil
        update(text: text, selection: selection, language: language, runWhenPlanned: ranBefore)
    }

    /// ⇥ / ⇧⇥: the plugin's next option, applied.
    func cycle(_ step: Int, selection: String?, text: String, language: AppLanguage) -> Bool {
        guard let plugin, let request, let plan else { return false }
        guard let options = plugin.nextOptions(after: plan, request: request, step: step) else { return false }
        rerun(with: options, selection: selection, text: text, language: language)
        return true
    }

    var plan: AskPluginPlan? {
        switch phase {
        case .waiting: nil
        case let .ready(plan), let .running(plan), let .done(plan, _), let .failed(plan, _): plan
        }
    }

    /// The shown plan was made for the text as it is now, so its actions apply to it.
    var isPlanCurrent: Bool { plannedFor != nil && plannedFor == request }

    /// Esc while running: back to ready. False when nothing was running.
    func cancelRun() -> Bool {
        pendingRun = false
        guard case let .running(plan) = phase else { return false }
        cancel()
        generation += 1
        set(\.phase, .ready(plan))
        return true
    }

    private func execute(_ plan: AskPluginPlan, request: AskPluginRequest, generation current: Int,
                         plugin: any AskLauncherPlugin, shown: AskPluginOutput? = nil) async {
        do {
            var output = try await plugin.run(request, plan: plan) { [weak self] partial in
                guard let self, current == self.generation, self.isRunning else { return }
                self.set(\.partial, partial)
            }
            guard !Task.isCancelled, current == generation else { return }
            if let shown {
                // A timed rerun keeps the chosen row, and its actions already ran for the first result.
                output.followUp = shown.followUp
                output.selectedItem = Self.selection(keeping: shown, in: output)
            }
            set(\.previous, nil)
            adopt(output.variables)
            set(\.phase, .done(plan, output))
            shownAt = clock()
            if output.recordsAtOnce, let lookup = output.wordBook { recordWordBook?(lookup) }
            scheduleRerun(of: output, plan: plan, generation: current, plugin: plugin)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            let failure = error as? AskPluginFailure ?? AskPluginFailure(message: error.localizedDescription)
            set(\.previous, nil)
            set(\.phase, .failed(plan, failure))
        }
    }

    // MARK: - Lists

    /// Moves the chosen row of a list by `delta`. False at either end, or without a
    /// list, so the arrows can move on to "Ask AI".
    func moveSelection(_ delta: Int) -> Bool {
        guard case let .done(plan, output) = phase, !output.items.isEmpty else { return false }
        let next = output.selectedItem + delta
        guard output.items.indices.contains(next) else { return false }
        var moved = output
        moved.selectedItem = next
        set(\.phase, .done(plan, moved))
        return true
    }

    /// Chooses a row (a click, or the arrows coming back from "Ask AI").
    func selectItem(_ index: Int) {
        guard case let .done(plan, output) = phase, !output.items.isEmpty else { return }
        var chosen = output
        chosen.selectedItem = min(max(0, index), output.items.count - 1)
        set(\.phase, .done(plan, chosen))
    }

    /// The row that was chosen before, found by its id in the new list; else the same place.
    static func selection(keeping shown: AskPluginOutput, in output: AskPluginOutput) -> Int {
        guard !output.items.isEmpty else { return 0 }
        if let id = shown.selected?.id, let index = output.items.firstIndex(where: { $0.id == id }) { return index }
        return min(shown.selectedItem, output.items.count - 1)
    }

    /// A workflow's `variables` become options for every later run in this keyword
    /// mode. The current request takes them too, so it still counts as the one shown.
    private func adopt(_ variables: [String: String]) {
        guard !variables.isEmpty else { return }
        overrides.merge(variables) { $1 }
        request?.options.merge(variables) { $1 }
        plannedFor?.options.merge(variables) { $1 }
    }

    /// A list that asks to run again (`rerun`) does, quietly, while it is shown.
    /// Anything that changes the request or leaves keyword mode cancels it.
    private func scheduleRerun(of output: AskPluginOutput, plan: AskPluginPlan, generation current: Int,
                               plugin: any AskLauncherPlugin) {
        guard let seconds = output.rerunAfter else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(AskWorkflowItemList.minimumRerun, seconds)))
            guard let self, !Task.isCancelled, current == self.generation, let request = self.request,
                  case let .done(_, shown) = self.phase else { return }
            await self.execute(plan, request: request, generation: current, plugin: plugin, shown: shown)
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        shownAt = nil
        set(\.partial, nil)
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<AskPluginSession, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}

// MARK: - Word book

extension AskPluginSession {
    /// The shown result was used (copied, read aloud, starred…) or stayed long enough:
    /// the word it looked up goes into the word book.
    func settleWordBook() {
        guard let lookup = output?.wordBook else { return }
        recordWordBook?(lookup)
    }

    /// Shows the word as starred or not without running again.
    func showStarred(_ starred: Bool, key: String) {
        guard case let .done(plan, output) = phase, output.wordBook?.key == key else { return }
        set(\.phase, .done(plan, output.starring(starred)))
    }
}

// MARK: - runKeyword

extension AskPluginSession {
    /// A workflow's `runKeyword`: enters `found` with `text` after it and runs it at
    /// once, remembering `chain` (the keywords so far) for the run's own actions.
    func chain(to found: AskKeyword, text: String, chain: [String], selection: String?, language: AppLanguage) {
        guard plugin(for: found) != nil else { return }
        deactivate()
        set(\.hint, nil)
        activate(found)
        chained = (chain, text.trimmingCharacters(in: .whitespacesAndNewlines))
        update(text: text, selection: selection, language: language, runWhenPlanned: true)
    }

    /// The chain a request for `text` carries: the one `runKeyword` started while the
    /// text is still what it put in; typing something else starts a chain of its own.
    private func chain(for text: String) -> [String] {
        if chained?.text != text {
            chained = nil
        }
        return chained?.keywords ?? []
    }
}
