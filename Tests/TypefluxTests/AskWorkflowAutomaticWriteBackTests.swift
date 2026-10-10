import Foundation
import Testing
@testable import Typeflux

@Suite("Ask workflow automatic write back", .serialized, .exclusiveUIState)
@MainActor
struct AskWorkflowAutomaticWriteBackTests {
    private func run(query: String = "typed", selection: String? = nil,
                     origin: AskPluginRequest.Origin = .argument,
                     display: String = "text", close: Bool = false,
                     scriptActions: Bool = false, fails: Bool = false) async throws -> AskPluginOutput {
        let fixture = try AskWorkflowFixture()
        let actions: [[String: Any]] = [
            ["action": "writeBack", "value": "{output}"],
            ["action": "copy", "value": "{output}"]
        ]
        let text = scriptActions
            ? #"{"text":"result","actions":[{"action":"writeBack","value":"script result"},{"action":"hud","text":"done"}]}"#
            : "result"
        let script = "print -r -- '\(text)'" + (fails ? "\nexit 1" : "")
        try fixture.write("local.preview", manifest: AskWorkflowFixture.inline(
            "local.preview", script: script, extra: [
                "input": ["selection": "always"],
                "output": ["display": display, "close": close, "scriptActions": scriptActions,
                           fails ? "onFailure" : "onSuccess": actions]
            ]
        ))
        fixture.store.reload()
        fixture.store.trust("local.preview")
        let workflow = try #require(fixture.store.workflow("local.preview"))
        let plugin = AskWorkflowPlugin(workflow: workflow, searchPath: { "/usr/bin:/bin" }, home: fixture.home.path)
        let request = AskPluginRequest(text: query, origin: origin, keyword: plugin.defaultKeywords[0], options: [:],
                                       interfaceLanguage: .english, selection: selection)
        return try await plugin.run(request, plan: await plugin.plan(request))
    }

    @Test(arguments: ["text", "auto", "markdown", "items", "image"])
    func typedResultsKeepTheWindowAndManualWriteBack(display: String) async throws {
        let output = try await run(display: display)
        #expect(!output.dismisses)
        #expect(output.followUp?.closes == false)
        #expect(output.followUp?.steps.map(\.action.action) == ["copy"])
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("result"))
    }

    @Test(arguments: ["typed", "min", "pretty"])
    func anArgumentDoesNotAutomaticallyOverwriteACapturedSelection(query: String) async throws {
        let output = try await run(query: query, selection: "selected")
        #expect(output.followUp?.steps.map(\.action.action) == ["copy"])
        #expect(!output.dismisses && output.followUp?.closes == false)
    }

    @Test(arguments: [nil, ""] as [String?])
    func noSelectionKeepsGeneratedResults(selection: String?) async throws {
        let output = try await run(query: "", selection: selection)
        #expect(output.followUp?.steps.map(\.action.action) == ["copy"])
        #expect(!output.dismisses && output.followUp?.closes == false)
    }

    @Test func aSelectionOnlyRunStillReplacesTheSelection() async throws {
        let output = try await run(query: "selected", selection: "selected", origin: .selection)
        #expect(output.followUp?.steps.map(\.action.action) == ["writeBack", "copy"])
    }

    @Test func scriptWriteBackUsesTheSamePolicyAsManifestWriteBack() async throws {
        let typed = try await run(scriptActions: true)
        #expect(typed.body == "result")
        #expect(typed.followUp?.steps.map(\.action.action) == ["copy", "hud"])
        let selected = try await run(query: "", selection: "selected", scriptActions: true)
        #expect(selected.followUp?.steps.map(\.action.action) == ["writeBack", "copy", "writeBack", "hud"])
    }

    @Test func failureActionsDoNotWriteIntoTheSourceAppForTypedInput() async throws {
        do {
            _ = try await run(fails: true)
            Issue.record("Expected the workflow to fail")
        } catch let failure as AskPluginFailure {
            #expect(failure.followUp?.steps.map(\.action.action) == ["copy"])
            #expect(failure.followUp?.closes == false)
        }
    }

    @Test func explicitlyClosingAndActionOnlyWorkflowsStillRunTheirActions() async throws {
        for (display, close) in [("text", true), ("none", false)] {
            let output = try await run(display: display, close: close)
            #expect(output.followUp?.closes == true)
            #expect(output.followUp?.steps.map(\.action.action) == ["writeBack", "copy"])
        }
    }

    @Test func theInstalledGalleryJSONKeepsTypedResultsAndReplacesSelectionOnlyInput() async throws {
        let fixture = try AskWorkflowFixture()
        let item = try #require(AskWorkflowGallery.bundled.item("json"))
        let workflow = try fixture.store.add(item, builtIn: []).workflow
        let plugin = AskWorkflowPlugin(workflow: workflow, home: fixture.home.path)
        let inputs: [(String, String?)] = [(#"{"a":1}"#, nil), ("", #"{"a":1}"#), ("min", #"{"a":1}"#)]
        for (query, selection) in inputs {
            let request = AskPluginRequest(text: query, origin: .argument, keyword: plugin.defaultKeywords[0],
                                           options: [:], interfaceLanguage: .english, selection: selection)
            let output = try await plugin.run(request, plan: await plugin.plan(request))
            #expect(output.body.contains("\"a\""))
            #expect(!output.dismisses)
            if query.isEmpty {
                #expect(output.followUp?.steps.map(\.action.action) == ["writeBack"])
            } else {
                #expect(output.followUp == nil)
                #expect(output.action(for: .optionEnter)?.kind == .writeBack(output.body))
            }
        }
    }
}
