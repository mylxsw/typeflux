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

    private let plugins: [String: any AskLauncherPlugin]
    private var keywords: () -> [AskKeyword]
    private var overrides: [String: String] = [:]
    /// The request the shown plan was made for; the text may have moved on since.
    private var plannedFor: AskPluginRequest?
    /// Return came while the plan for the latest text was still being made.
    private var pendingRun = false
    private var generation = 0
    private var task: Task<Void, Never>?
    /// How long a live plugin waits after the last keystroke.
    var debounce: Duration = .milliseconds(250)

    init(plugins: [any AskLauncherPlugin], keywords: @escaping () -> [AskKeyword]) {
        self.plugins = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.keywords = keywords
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
        set(\.keyword, found)
        set(\.phase, .waiting)
    }

    /// Leaves keyword mode, returning the text to put back in the editor: the
    /// keyword (⌫ on an empty argument) or the keyword and its argument (closing).
    @discardableResult
    func deactivate(argument: String = "") -> String? {
        guard let keyword else { return nil }
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
        let next: AskPluginRequest?
        if !trimmed.isEmpty {
            next = AskPluginRequest(text: trimmed, origin: .argument, keyword: keyword,
                                    options: keyword.options.merging(overrides) { $1 }, interfaceLanguage: language)
        } else if let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty {
            next = AskPluginRequest(text: selection, origin: .selection, keyword: keyword,
                                    options: keyword.options.merging(overrides) { $1 }, interfaceLanguage: language)
        } else {
            next = nil
        }
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
                         plugin: any AskLauncherPlugin) async {
        do {
            let output = try await plugin.run(request, plan: plan) { [weak self] partial in
                guard let self, current == self.generation, self.isRunning else { return }
                self.set(\.partial, partial)
            }
            guard !Task.isCancelled, current == generation else { return }
            set(\.previous, nil)
            set(\.phase, .done(plan, output))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            let failure = error as? AskPluginFailure ?? AskPluginFailure(message: error.localizedDescription)
            set(\.previous, nil)
            set(\.phase, .failed(plan, failure))
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        set(\.partial, nil)
    }

    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<AskPluginSession, Value>, _ value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }
}
