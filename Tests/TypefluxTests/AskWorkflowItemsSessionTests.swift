import AppKit
import Foundation
import Testing
@testable import Typeflux

/// A plugin that returns a list, counting its runs: rows "a", "b", "c" (or what
/// `rows` says), a rerun interval and variables.
final class AskListTestPlugin: AskLauncherPlugin, @unchecked Sendable {
    var rows = ["a", "b", "c"]
    var rerun: Double?
    var variables: [String: String] = [:]
    var followUp: AskWorkflowFollowUp?
    private(set) var runs: [AskPluginRequest] = []

    let id = "list"
    let title = "List"
    let symbol = "list.bullet"
    var defaultKeywords: [AskKeyword] {
        [AskKeyword(keyword: "ls", pluginID: id)]
    }

    var runsWithoutInput: Bool {
        true
    }

    func placeholder(selectionLines _: Int?) -> String {
        ""
    }

    func chipDetail(for _: AskKeyword, language _: AppLanguage) -> String? {
        nil
    }

    func plan(_: AskPluginRequest) async -> AskPluginPlan {
        AskPluginPlan(mode: .onSubmit, title: "list")
    }

    func nextOptions(after _: AskPluginPlan, request _: AskPluginRequest, step _: Int) -> [String: String]? {
        nil
    }

    func run(_ request: AskPluginRequest, plan _: AskPluginPlan,
             progress _: @escaping AskPluginProgress) async throws -> AskPluginOutput {
        runs.append(request)
        var output = AskPluginOutput(
            body: rows.joined(separator: "\n"),
            original: request.text,
            meta: [],
            source: "test",
            actions: []
        )
        output.items = rows.map { AskPluginItem(id: $0, title: $0) }
        output.rerunAfter = rerun
        output.variables = variables
        // A new id on every run, as a workflow's follow-up has.
        output.followUp = followUp.map { AskWorkflowFollowUp(steps: $0.steps, closes: $0.closes) }
        return output
    }
}

@Suite("Ask plugin session lists", .serialized, .exclusiveUIState)
@MainActor
struct AskPluginSessionListTests {
    private func session(_ plugin: AskListTestPlugin) -> AskPluginSession {
        let session = AskPluginSession(plugins: [plugin]) { plugin.defaultKeywords }
        _ = session.detect(in: "ls ")
        return session
    }

    private func wait(_ condition: () -> Bool) async {
        for _ in 0 ..< 600 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func `the arrows move through the rows and stop at the ends`() async {
        let plugin = AskListTestPlugin()
        let session = session(plugin)
        #expect(!session.moveSelection(1), "nothing to move through yet")
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        await wait { session.output != nil }
        #expect(session.output?.selectedItem == 0)
        #expect(session.moveSelection(1) && session.moveSelection(1))
        #expect(session.output?.selected?.id == "c")
        #expect(!session.moveSelection(1) && session.output?.selectedItem == 2)
        #expect(session.moveSelection(-2) && !session.moveSelection(-1))
        session.selectItem(9)
        #expect(session.output?.selectedItem == 2, "a choice past the end takes the last row")
        session.selectItem(-3)
        #expect(session.output?.selectedItem == 0)
    }

    @Test func `variables come back as options on the next run`() async {
        let plugin = AskListTestPlugin()
        plugin.variables = ["scope": "mine"]
        let session = session(plugin)
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        await wait { session.output != nil }
        #expect(session.request?.options["scope"] == "mine" && session.isPlanCurrent,
                "the shown request takes them and stays current")
        session.update(text: "x", selection: nil, language: .english)
        #expect(plugin.runs.count == 1, "the same text is not a new request")
        session.rerun(with: [:], selection: nil, text: "y", language: .english)
        await wait { plugin.runs.count == 2 && session.output != nil }
        #expect(plugin.runs.last?.options["scope"] == "mine")
        session.deactivate()
        _ = session.detect(in: "ls ")
        session.update(text: "z", selection: nil, language: .english, runWhenPlanned: true)
        await wait { plugin.runs.count == 3 }
        #expect(plugin.runs.last?.options["scope"] == nil, "a new keyword mode starts without them")
    }

    @Test func `a list that asks to rerun does quietly and keeps the chosen row`() async throws {
        let plugin = AskListTestPlugin()
        plugin.rerun = 0.5
        plugin.followUp = AskWorkflowFollowUp(steps: [], closes: false)
        let session = session(plugin)
        session.update(text: "x", selection: nil, language: .english, runWhenPlanned: true)
        await wait { session.output != nil }
        let first = try #require(session.output?.followUp)
        #expect(session.moveSelection(1))
        plugin.rows = ["new", "b", "c"]
        await wait { plugin.runs.count >= 2 && session.output?.items.first?.id == "new" }
        #expect(plugin.runs.count >= 2)
        #expect(session.output?.selected?.id == "b", "the row is found again by its id")
        #expect(session.output?.followUp?.id == first.id, "the actions ran for the first result only")
        plugin.rows = ["x", "y"]
        await wait { session.output?.items.first?.id == "x" }
        #expect(session.output?.selectedItem == 1, "a row that is gone keeps the place")
        session.deactivate()
        let runs = plugin.runs.count
        try await Task.sleep(for: .milliseconds(800))
        #expect(plugin.runs.count == runs, "leaving keyword mode stops it")
    }

    @Test func `the chosen row is found by id or keeps its place`() {
        func output(_ ids: [String], selected: Int = 0) -> AskPluginOutput {
            var output = AskPluginOutput(body: "", original: "", meta: [], source: "", actions: [])
            output.items = ids.map { AskPluginItem(id: $0, title: $0) }
            output.selectedItem = selected
            return output
        }
        #expect(AskPluginSession.selection(keeping: output(["a", "b"], selected: 1), in: output(["b", "a"])) == 0)
        #expect(AskPluginSession.selection(keeping: output(["a", "b", "c"], selected: 2), in: output(["x", "y"])) == 1)
        #expect(AskPluginSession.selection(keeping: output(["a"]), in: output([])) == 0)
    }
}

@Suite("Ask workflow lists and Markdown in the plugin", .exclusiveUIState)
@MainActor
struct AskWorkflowItemPluginTests {
    /// What the run showed while it went on.
    @MainActor final class Partials {
        var outputs: [AskPluginOutput] = []
    }

    private func run(_ script: String, output outputSetting: Any, query: String = "in",
                     selection: String? = nil) async throws -> AskPluginOutput {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.l", manifest: AskWorkflowFixture.inline("local.l", keyword: "l", script: script,
                                                                         extra: ["output": outputSetting]))
        fixture.store.reload()
        fixture.store.trust("local.l")
        let workflow = try #require(fixture.store.workflow("local.l"))
        let plugin = AskWorkflowPlugin(workflow: workflow, home: fixture.home.path)
        let request = AskPluginRequest(text: query.isEmpty ? selection ?? "" : query,
                                       origin: query.isEmpty ? .selection : .argument,
                                       keyword: plugin.defaultKeywords[0], options: [:], interfaceLanguage: .english,
                                       selection: selection)
        let plan = await plugin.plan(request)
        let partials = Partials()
        let output = try await plugin.run(request, plan: plan) { partials.outputs.append($0) }
        if (outputSetting as? String) == "items" {
            #expect(partials.outputs.isEmpty, "a list does not show while it is printed")
        }
        return output
    }

    @Test func `a list becomes rows with the result's own keys`() async throws {
        let script = #"""
        print -r -- '{"items": [{"uid": "1", "title": "One", "subtitle": "first", "arg": "https://one.dev"},'
        print -r -- '{"title": "Two", "arg": "two", "action": "paste"}], "rerun": 3, "variables": {"k": "v"}}'
        """#
        let output = try await run(script, output: "items", query: "", selection: "sel")
        #expect(output.items.map(\.title) == ["One", "Two"] && output.items[0].id == "uid:1")
        #expect(try output.action(for: .enter)?.kind == .open(#require(URL(string: "https://one.dev"))))
        #expect(output.body == "One\nTwo" && output.rerunAfter == 3 && output.variables == ["k": "v"])
        #expect(output.actions.map(\.shortcut) == [.commandR, .commandE], "copy, write back and compare belong to rows")
        #expect(output.items[1].actions.first?.title == L("ask.plugin.action.replace"),
                "with only the selection, pasting replaces it")
        #expect(!output.markdown && output.note == nil)
    }

    @Test func `auto lists only what is a list`() async throws {
        let list = try await run(#"print -r -- '{"items": []}'"#, output: "auto")
        #expect(list.items.map(\.title) == [L("ask.workflow.items.empty")])
        let text = try await run("print -r -- hello", output: "auto")
        #expect(text.items.isEmpty && text.body == "hello" && text.note == nil)
        let card = try await run(#"print -r -- '{"text": "card"}'"#, output: "items")
        #expect(card.items.isEmpty && card.body == "card" && card.action(for: .enter)?.kind == .copy("card"))
        let broken = try await run("print -r -- oops", output: "items")
        #expect(broken.body == "oops" && broken.note == L("ask.workflow.items.invalid"))
    }

    @Test func `markdown is drawn and copied as written`() async throws {
        let output = try await run(#"print -r -- '# Title'; print -r -- '- a'"#, output: "markdown")
        #expect(output.markdown && output.body == "# Title\n- a" && output.items.isEmpty)
        #expect(output.action(for: .enter)?.kind == .copy("# Title\n- a"))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("# Title\n- a"))
    }

    @Test func `list actions still run after the run`() async throws {
        let output = try await run(#"print -r -- '{"items": [{"title": "A", "arg": "a"}]}'"#, output: [
            "display": "items", "onSuccess": [["action": "copy", "value": "{json.items.0.title}"]]
        ])
        #expect(output.followUp?.steps.map(\.effect) == [.copy("A")])
    }
}
