import Foundation
import Testing
@testable import Typeflux

extension AskLauncherPlugin {
    /// Runs without watching the progress.
    func run(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput {
        try await run(request, plan: plan) { _ in }
    }
}

/// A plugin whose plans and results the test decides, recording every run.
/// With `steps`, it reports each one as progress before finishing.
final class AskTestPlugin: AskLauncherPlugin, @unchecked Sendable {
    /// `plan` and `run` execute off the main actor while the test reconfigures the plugin, and a
    /// cancelled run can still be starting when the next one records itself. Every mutable value
    /// is therefore read and written under one lock.
    private struct State {
        var live = true
        var failure: AskPluginFailure?
        var runDelay: Duration = .zero
        var steps: [String] = []
        var stepDelay: Duration = .milliseconds(20)
        var planActions: [AskPluginAction] = []
        var noInput = false
        var runs: [AskPluginRequest] = []
    }

    private let lock = NSLock()
    private var state = State()

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var live: Bool { get { locked { $0.live } } set { locked { $0.live = newValue } } }
    var failure: AskPluginFailure? { get { locked { $0.failure } } set { locked { $0.failure = newValue } } }
    var runDelay: Duration { get { locked { $0.runDelay } } set { locked { $0.runDelay = newValue } } }
    var steps: [String] { get { locked { $0.steps } } set { locked { $0.steps = newValue } } }
    var stepDelay: Duration { get { locked { $0.stepDelay } } set { locked { $0.stepDelay = newValue } } }
    var planActions: [AskPluginAction] {
        get { locked { $0.planActions } }
        set { locked { $0.planActions = newValue } }
    }
    var noInput: Bool { get { locked { $0.noInput } } set { locked { $0.noInput = newValue } } }
    var runsWithoutInput: Bool { noInput }
    var runs: [AskPluginRequest] { locked { $0.runs } }

    let id = "test"
    let title = "Test"
    let symbol = "star"
    var defaultKeywords: [AskKeyword] { [AskKeyword(keyword: "tt", pluginID: id)] }

    func placeholder(selectionLines: Int?) -> String { "type" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { keyword.options["target"] }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let (live, planActions) = locked { ($0.live, $0.planActions) }
        let mode: AskPluginPlan.Mode = live && request.origin == .argument && request.options["engine"] == nil ? .live : .onSubmit
        return AskPluginPlan(mode: mode, title: "plan " + request.text, values: request.options, actions: planActions)
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        let (runDelay, steps, stepDelay) = locked { state in
            state.runs.append(request)
            return (state.runDelay, state.steps, state.stepDelay)
        }
        if runDelay != .zero { try await Task.sleep(for: runDelay) }
        var text = ""
        for step in steps {
            text += step
            await progress(AskPluginOutput(body: text, original: request.text, meta: [], source: "test", actions: []))
            try await Task.sleep(for: stepDelay)
        }
        if let failure = locked({ $0.failure }) { throw failure }
        return AskPluginOutput(body: "done " + request.text, original: request.text, meta: [], source: "test",
                               actions: [AskPluginAction(kind: .copy("done " + request.text), title: "Copy",
                                                         symbol: "doc", shortcut: .enter)])
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        step > 0 ? ["target": "next"] : nil
    }
}

@Suite("Ask plugin session", .serialized, .exclusiveUIState)
@MainActor
struct AskPluginSessionTests {
    func session(_ plugin: AskTestPlugin = AskTestPlugin()) -> AskPluginSession {
        let session = AskPluginSession(plugins: [plugin]) { plugin.defaultKeywords + [AskKeyword(keyword: "zz", pluginID: "missing")] }
        session.debounce = .milliseconds(10)
        return session
    }

    func settle(_ session: AskPluginSession, until condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "timed out")
    }

    @Test func keywordsBecomeChipsAndHints() {
        let session = session()
        #expect(session.availableKeywords.map(\.keyword) == ["tt"], "keywords without a plugin are ignored")
        #expect(session.detect(in: "hello") == nil && session.hint == nil)
        #expect(session.detect(in: "tt") == nil)
        #expect(session.hint?.keyword == "tt")
        #expect(session.detect(in: "zz x") == nil, "no plugin, no keyword")
        #expect(session.detect(in: "tt hello") == "hello")
        #expect(session.isActive && session.hint == nil && session.plugin?.id == "test")
        #expect(session.detect(in: "tt again") == nil, "one keyword at a time")
        #expect(session.deactivate(argument: "hello") == "tt hello")
        #expect(!session.isActive && session.deactivate() == nil)
        _ = session.detect(in: "tt")
        #expect(session.acceptHint() && session.isActive && session.hint == nil)
        #expect(!session.acceptHint())
        #expect(session.deactivate() == "tt")
    }

    @Test func typedTextRunsLiveAndKeepsTheLastResultWhileTheNextRuns() async throws {
        let plugin = AskTestPlugin()
        let session = session(plugin)
        _ = session.detect(in: "tt ")
        session.update(text: "", selection: nil, language: .english)
        #expect(session.phase == .waiting)
        session.update(text: "hello", selection: nil, language: .english)
        try await settle(session) { session.output != nil }
        #expect(session.output?.body == "done hello")
        #expect(session.request?.origin == .argument)
        plugin.runDelay = .milliseconds(80)
        session.update(text: "hello there", selection: nil, language: .english)
        try await settle(session) { session.isRunning }
        #expect(session.previous?.body == "done hello", "the old result stays, dimmed")
        try await settle(session) { session.output?.body == "done hello there" }
        #expect(session.previous == nil)
        session.update(text: "hello there", selection: nil, language: .english)
        #expect(plugin.runs.count == 2, "the same request does not run again")
    }

    @Test func theSelectionWaitsForReturn() async throws {
        let plugin = AskTestPlugin()
        let session = session(plugin)
        _ = session.detect(in: "tt ")
        session.update(text: "  ", selection: " picked words ", language: .english)
        try await settle(session) { if case .ready = session.phase { true } else { false } }
        #expect(session.request?.origin == .selection && session.request?.text == "picked words")
        #expect(plugin.runs.isEmpty, "nothing is translated before Return")
        #expect(session.plan?.title == "plan picked words")
        #expect(session.run())
        try await settle(session) { session.output != nil }
        #expect(plugin.runs.count == 1)
        #expect(!session.run(), "a finished request does not run on Return")
        session.update(text: "", selection: nil, language: .english)
        #expect(session.phase == .waiting && session.previous == nil && session.plan == nil)
    }

    @Test func failuresCanBeRetriedAndRunsCancelled() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        plugin.failure = AskPluginFailure(message: "offline")
        let session = session(plugin)
        _ = session.detect(in: "tt x")
        session.update(text: "x", selection: nil, language: .english)
        try await settle(session) { session.plan != nil }
        #expect(session.run())
        try await settle(session) { if case .failed = session.phase { true } else { false } }
        plugin.failure = nil
        plugin.runDelay = .milliseconds(200)
        #expect(session.run(), "Return retries")
        #expect(session.isRunning)
        #expect(session.cancelRun())
        if case .ready = session.phase {} else { Issue.record("cancel returns to ready") }
        #expect(!session.cancelRun())
        plugin.failure = AskPluginFailure(message: "no", retry: false)
        plugin.runDelay = .zero
        #expect(session.run())
        try await settle(session) { if case .failed = session.phase { true } else { false } }
        #expect(!session.run(), "a failure without retry stays")
        // Any other error still lands as a failure with its description.
        let other = AskPluginSession(plugins: [ThrowingPlugin()]) { [AskKeyword(keyword: "th", pluginID: "throwing")] }
        _ = other.detect(in: "th x")
        other.update(text: "x", selection: nil, language: .english)
        try await settle(other) { other.plan != nil }
        #expect(other.run())
        try await settle(other) { if case .failed = other.phase { true } else { false } }
    }

    @Test func tabAndRerunApplyOptions() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        let session = session(plugin)
        _ = session.detect(in: "tt x")
        #expect(!session.cycle(1, selection: nil, text: "x", language: .english), "nothing planned yet")
        session.update(text: "x", selection: nil, language: .english)
        try await settle(session) { session.plan != nil }
        #expect(session.cycle(1, selection: nil, text: "x", language: .english))
        try await settle(session) { session.plan?.values["target"] == "next" }
        #expect(plugin.runs.isEmpty, "a request waiting for Return keeps waiting")
        #expect(!session.cycle(-1, selection: nil, text: "x", language: .english))
        #expect(session.run())
        try await settle(session) { session.output != nil }
        session.rerun(with: ["engine": "ai"], selection: nil, text: "x", language: .english)
        try await settle(session) { plugin.runs.count == 2 && session.output != nil }
        #expect(plugin.runs.last?.options == ["target": "next", "engine": "ai"], "a shown result runs again at once")
        session.comparing = true
        session.deactivate()
        #expect(!session.comparing)
    }
}

extension AskPluginSessionTests {
    @Test func aStreamingRunShowsItsTextAsItGrows() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        plugin.steps = ["Hel", "lo"]
        plugin.stepDelay = .milliseconds(60)
        let session = session(plugin)
        _ = session.detect(in: "tt x")
        session.update(text: "x", selection: nil, language: .english)
        try await settle(session) { session.plan != nil }
        #expect(session.run())
        try await settle(session) { session.partial?.body == "Hel" }
        #expect(session.isRunning)
        try await settle(session) { session.partial?.body == "Hello" }
        try await settle(session) { session.output != nil }
        #expect(session.partial == nil, "the finished result replaces the partial one")
        // Esc drops what had arrived.
        session.rerun(with: [:], selection: nil, text: "x", language: .english)
        try await settle(session) { session.partial != nil }
        #expect(session.cancelRun())
        #expect(session.partial == nil)
    }

    @Test func returnRightAfterTypingRunsTheLatestText() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        let session = session(plugin)
        _ = session.detect(in: "tt a")
        session.update(text: "a", selection: nil, language: .english)
        try await settle(session) { session.plan != nil }
        #expect(session.isPlanCurrent)
        session.update(text: "ab", selection: nil, language: .english)
        #expect(!session.isPlanCurrent, "the shown plan is still for \"a\"")
        #expect(session.run(), "Return is taken and waits for the new plan")
        try await settle(session) { session.output != nil }
        #expect(plugin.runs.map(\.text) == ["ab"])
        // A waiting Return does not outlive the keyword.
        let quiet = AskTestPlugin()
        quiet.live = false
        let other = self.session(quiet)
        _ = other.detect(in: "tt a")
        other.update(text: "a", selection: nil, language: .english)
        try await settle(other) { other.plan != nil }
        other.update(text: "ab", selection: nil, language: .english)
        #expect(other.run())
        other.deactivate()
        _ = other.detect(in: "tt ab")
        other.update(text: "ab", selection: nil, language: .english)
        try await settle(other) { other.plan != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(quiet.runs.isEmpty, "nothing runs on its own")
    }

    @Test func pluginsThatNeedNoInputPlanAtOnceAndCanBeSwapped() async throws {
        let plugin = AskTestPlugin()
        plugin.live = false
        plugin.noInput = true
        let session = session(plugin)
        _ = session.detect(in: "tt ")
        session.update(text: "", selection: "  ", language: .english)
        try await settle(session) { session.plan != nil }
        #expect(session.request?.text == "" && session.request?.origin == .argument)
        session.update(text: "x", selection: " sel ", language: .english)
        #expect(session.request?.selection == "sel", "the selection rides along with typed text")
        session.replacePlugins([plugin])
        #expect(session.isActive, "the same plugin stays")
        session.replacePlugins([])
        #expect(!session.isActive && session.availableKeywords.isEmpty)
        let other = self.session(plugin)
        _ = other.detect(in: "tt")
        #expect(other.hint != nil)
        other.replacePlugins([])
        #expect(other.hint == nil)
    }

    @Test func thePaletteEntersAKeyword() {
        let session = session()
        session.enter(AskKeyword(keyword: "zz", pluginID: "missing"))
        #expect(!session.isActive, "a keyword without its plugin is ignored")
        _ = session.detect(in: "tt")
        session.enter(AskKeyword(keyword: "tt", pluginID: "test"))
        #expect(session.isActive && session.hint == nil)
        session.enter(AskKeyword(keyword: "tt2", pluginID: "test", options: ["target": "x"]))
        #expect(session.keyword?.keyword == "tt2", "a chosen keyword replaces the active one")
    }
}

/// A plugin that fails with an error that is not a plugin failure.
private struct ThrowingPlugin: AskLauncherPlugin {
    struct Broken: Error {}
    let id = "throwing", title = "Throwing", symbol = "xmark"
    var defaultKeywords: [AskKeyword] { [] }
    func placeholder(selectionLines: Int?) -> String { "" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan { AskPluginPlan(mode: .onSubmit, title: "t") }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan,
             progress: @escaping AskPluginProgress) async throws -> AskPluginOutput { throw Broken() }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}

@Suite("Ask test plugin")
struct AskTestPluginTests {
    /// Runs overlap and the test reconfigures the plugin meanwhile, as a cancelled run that is
    /// still starting does next to a retry. Every run is recorded and none is lost or corrupted.
    @Test func concurrentRunsAndReconfigurationAreRecordedSafely() async throws {
        let plugin = AskTestPlugin()
        plugin.stepDelay = .zero
        let keyword = try #require(plugin.defaultKeywords.first)
        let plan = AskPluginPlan(mode: .onSubmit, title: "t")
        let count = 200
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< count {
                group.addTask {
                    let request = AskPluginRequest(text: "\(index)", origin: .argument, keyword: keyword,
                                                   options: [:], interfaceLanguage: .english)
                    _ = try? await plugin.run(request, plan: plan)
                }
                group.addTask {
                    plugin.failure = index.isMultiple(of: 2) ? AskPluginFailure(message: "offline \(index)") : nil
                    plugin.steps = index.isMultiple(of: 3) ? ["a"] : []
                }
            }
            try await group.waitForAll()
        }
        #expect(Set(plugin.runs.map(\.text)) == Set((0 ..< count).map(String.init)))
    }
}
