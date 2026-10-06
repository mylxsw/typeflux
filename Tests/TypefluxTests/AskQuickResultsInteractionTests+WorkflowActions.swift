import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Workflow actions that copy: the test panel's real run and the launcher's bottom
/// bar. They swap the copy pasteboard like the other launcher tests, so they live in
/// this serialized suite and take turns with them.
extension AskQuickResultsInteractionTests {
    private func editor(_ fixture: AskWorkflowFixture, output: Any) throws -> AskWorkflowEditorModel {
        try fixture.write("local.fx", manifest: AskWorkflowFixture.inline(
            "local.fx", keyword: "fx", script: "print -r -- \"$1 = 42\"\nprint -r -- last",
            extra: ["output": output, "name": "FX"]
        ))
        fixture.store.reload()
        fixture.store.trust("local.fx")
        let defaults = try #require(UserDefaults(suiteName: "wf-actions-\(UUID().uuidString)"))
        let assistant = AskWorkflowAssistant(dependencies: .init(
            api: AskWorkflowScriptedAPI([]), session: { ("owner", "token") }, deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), defaults: defaults
        ))
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        model.open("local.fx")
        return model
    }

    @Test func aTestRunCanRunTheActionsForReal() async throws {
        try await withPasteboard { pasteboard in
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, output: ["display": "text", "onSuccess": [
                ["action": "copy", "value": "{output.line1}"], ["action": "hud", "text": "done {keyword}"]
            ]])
            model.previewActionsOnly = false
            model.testQuery = "x"
            model.runTest()
            for _ in 0 ..< 1000 where model.isTesting {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(model.results.last?.actionOutcomes.map(\.status) == [.done, .done])
            #expect(pasteboard.string(forType: .string) == "x = 42")
            #expect(model.results.last?.actionSteps.last?.detail == "done fx", "the bar note shows in the action list")
            #expect(model.message == nil)
        }
    }

    @Test func theEditorHostCopiesAndAsksBeforeLeaving() async throws {
        try await withPasteboard { pasteboard in
            let fixture = try AskWorkflowFixture()
            let model = try editor(fixture, output: "text")
            let host = AskWorkflowEditorActionHost(model: model)
            var asked: [String] = []
            host.ask = { asked.append($0); return false }
            host.writeBack("w")
            #expect(pasteboard.string(forType: .string) == "w")
            #expect(model.message == L("ask.workflow.action.writeBackInTest"))
            host.copy("c")
            #expect(pasteboard.string(forType: .string) == "c")
            let step = AskWorkflowActionStep(action: .init(action: "open", target: "https://x"), detail: "https://x")
            #expect(await host.confirm(step) == false)
            #expect(asked == [L("ask.workflow.action.confirm", step.title, "https://x")])
            host.askAI("ignored")
            host.hud("note")
            #expect(model.message == L("ask.workflow.action.writeBackInTest"), "a note is not a warning")
        }
    }

    /// Screen ⑨: the result stays and the bottom bar sums up what the actions did
    /// (written to `implemented-launcher*.png` with TYPEFLUX_ASK_SNAPSHOTS set).
    @Test func theLauncherBarSumsUpTheActions() async throws {
        try await withPasteboard { pasteboard in
            let visuals = WorkflowOutputActionsVisualTests()
            try await visuals.chinese {
                let workflows = try AskWorkflowFixture()
                try workflows.write("local.fx", manifest: visuals.manifest,
                                    files: ["main.py": WorkflowOutputActionsVisualTests.script], executable: ["main.py"])
                workflows.store.reload()
                workflows.store.trust("local.fx")
                for light in [false, true] {
                    pasteboard.clearContents()
                    let fixture = try AskTestFixture()
                    defer { fixture.model.resetSession() }
                    let model = fixture.model
                    model.workflows = workflows.store
                    model.notifyUser = { _, _ in true }
                    _ = await AskWorkflowPath.searchPath()
                    await model.refreshLauncherWorkflows()
                    _ = model.plugins.detect(in: "fx 100 usd jpy")
                    model.launcherDraft.text = "100 usd jpy"
                    model.plugins.update(text: "100 usd jpy", selection: nil, language: .simplifiedChinese,
                                         runWhenPlanned: true)
                    await visuals.wait { model.plugins.output != nil }
                    // Run the actions here, so the bar is complete when the view is drawn.
                    let followUp = try #require(model.plugins.output?.followUp)
                    model.performWorkflowFollowUp(followUp) {}
                    await visuals.wait { model.currentWorkflowActions != nil }
                    #expect(model.currentWorkflowActions?.outcomes.count == 2)
                    #expect(pasteboard.string(forType: .string) == "100 USD = 14,912.30 JPY")
                    let view = AskLauncherView(model: model, onDismiss: {})
                        .environment(\.askGlassMaterialOverride, .opaque)
                    try await visuals.render(view, size: NSSize(width: AskMetrics.launcherWidth, height: 330),
                                             name: light ? "implemented-launcher-light.png" : "implemented-launcher.png",
                                             light: light)
                }
            }
        }
    }
}
