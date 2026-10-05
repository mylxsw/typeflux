import Foundation
import Testing
@testable import Typeflux

/// A plugin whose plans and results the test decides, recording every run.
final class AskTestPlugin: AskLauncherPlugin, @unchecked Sendable {
    var live = true
    var failure: AskPluginFailure?
    var runDelay: Duration = .zero
    private(set) var runs: [AskPluginRequest] = []

    let id = "test"
    let title = "Test"
    let symbol = "star"
    var defaultKeywords: [AskKeyword] { [AskKeyword(keyword: "tt", pluginID: id)] }

    func placeholder(selectionLines: Int?) -> String { "type" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { keyword.options["target"] }

    func plan(_ request: AskPluginRequest) async -> AskPluginPlan {
        let mode: AskPluginPlan.Mode = live && request.origin == .argument && request.options["engine"] == nil ? .live : .onSubmit
        return AskPluginPlan(mode: mode, title: "plan " + request.text, values: request.options)
    }

    func run(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput {
        runs.append(request)
        if runDelay != .zero { try await Task.sleep(for: runDelay) }
        if let failure { throw failure }
        return AskPluginOutput(body: "done " + request.text, original: request.text, meta: [], source: "test",
                               actions: [AskPluginAction(kind: .copy("done " + request.text), title: "Copy",
                                                         symbol: "doc", shortcut: .enter)])
    }

    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? {
        step > 0 ? ["target": "next"] : nil
    }
}

@Suite("Ask plugin session", .serialized)
@MainActor
struct AskPluginSessionTests {
    private func session(_ plugin: AskTestPlugin = AskTestPlugin()) -> AskPluginSession {
        let session = AskPluginSession(plugins: [plugin]) { plugin.defaultKeywords + [AskKeyword(keyword: "zz", pluginID: "missing")] }
        session.debounce = .milliseconds(10)
        return session
    }

    private func settle(_ session: AskPluginSession, until condition: () -> Bool) async throws {
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

/// A plugin that fails with an error that is not a plugin failure.
private struct ThrowingPlugin: AskLauncherPlugin {
    struct Broken: Error {}
    let id = "throwing", title = "Throwing", symbol = "xmark"
    var defaultKeywords: [AskKeyword] { [] }
    func placeholder(selectionLines: Int?) -> String { "" }
    func chipDetail(for keyword: AskKeyword, language: AppLanguage) -> String? { nil }
    func plan(_ request: AskPluginRequest) async -> AskPluginPlan { AskPluginPlan(mode: .onSubmit, title: "t") }
    func run(_ request: AskPluginRequest, plan: AskPluginPlan) async throws -> AskPluginOutput { throw Broken() }
    func nextOptions(after plan: AskPluginPlan, request: AskPluginRequest, step: Int) -> [String: String]? { nil }
}
