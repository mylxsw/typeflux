import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Script actions, images and `runKeyword` in the real launcher, driven by its keys.
/// They swap the copy pasteboard like the other launcher tests, so they live in this
/// serialized suite.
extension AskQuickResultsInteractionTests {
    private func enter(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 600 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "timed out")
    }

    private func launcher(_ workflows: AskWorkflowFixture, ids: [String],
                          prepare: @escaping (AskConversationModel) -> Void = { _ in }) async throws -> Launcher {
        workflows.store.reload()
        for id in ids {
            workflows.store.trust(id)
        }
        let launcher = try await Launcher(text: "") { model in
            model.workflows = workflows.store
            prepare(model)
        }
        _ = await AskWorkflowPath.searchPath()
        await launcher.fixture.model.refreshLauncherWorkflows()
        return launcher
    }

    @Test func `a script link to A new host is asked about once and remembered`() async throws {
        try await withPasteboard { _ in
            let workflows = try AskWorkflowFixture()
            let printed = #"{"text": "rate", "actions": [{"action": "open", "target": "https://www.xe.com/x"}]}"#
            try workflows.write("fx", manifest: AskWorkflowFixture.inline(
                "fx", keyword: "fx", script: AskWorkflowO4PluginTests.printing(printed),
                extra: ["output": ["display": "text", "scriptActions": true], "name": "FX"]
            ))
            var opened: [URL] = []
            let launcher = try await launcher(workflows, ids: ["fx"]) { model in model.openURL = { opened.append($0) } }
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await enter("fx 1", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.workflowApproval != nil }
            #expect(model.workflowApproval?.host == "www.xe.com" && model.workflowApproval?.workflowName == "FX")
            #expect(model.plugins.output?.body == "rate" && opened.isEmpty, "nothing opens before the answer")
            try await launcher.press(Self.escape)
            try await waitFor { model.currentWorkflowActions != nil }
            #expect(model.workflowApproval == nil && opened.isEmpty && launcher.dismissed == 0)
            #expect(model.currentWorkflowActions?.outcomes.first?.status
                == .skipped(L("ask.workflow.action.hostDeclined", "www.xe.com")))
            #expect(model.modelLibrary.settings.askWorkflowAllowedHosts["fx"] == nil, "a no is not remembered")
            // ⌘R runs it again; this time Return allows it.
            try await launcher.press(15, .command)
            try await waitFor { model.workflowApproval != nil }
            try await launcher.press(Self.returnKey)
            try await waitFor { !opened.isEmpty }
            #expect(opened.map(\.absoluteString) == ["https://www.xe.com/x"] && launcher.dismissed == 1)
            #expect(model.modelLibrary.settings.askWorkflowAllowedHosts["fx"] == ["www.xe.com"])
            // Remembered for this workflow: the next run opens it without asking.
            let host = AskWorkflowLauncherActionHost(model: model, workflowID: "fx", workflowName: "FX") {}
            #expect(await host.approve(host: "www.xe.com"))
            #expect(model.workflowApproval == nil)
        }
    }

    @Test func `a question left open is answered no`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let asked = Task { @MainActor in
            await model.requestWorkflowApproval(AskWorkflowApproval(workflowName: "A", host: "a.com"))
        }
        try await fixture.wait { model.workflowApproval != nil }
        model.finishPluginResult()
        #expect(await asked.value == false && model.workflowApproval == nil)
        let again = Task { @MainActor in
            await model.requestWorkflowApproval(AskWorkflowApproval(workflowName: "A", host: "b.com"))
        }
        try await fixture.wait { model.workflowApproval?.host == "b.com" }
        let newer = Task { @MainActor in
            await model.requestWorkflowApproval(AskWorkflowApproval(workflowName: "A", host: "c.com"))
        }
        try await fixture.wait { model.workflowApproval?.host == "c.com" }
        #expect(await again.value == false, "a newer question answers the older one no")
        model.answerWorkflowApproval(true)
        #expect(await newer.value == true)
        model.answerWorkflowApproval(true)
        // A closed launcher, or one handed to another keyword, cannot ask.
        let closed = AskWorkflowLauncherActionHost(model: model, workflowID: "w") {}
        closed.close()
        #expect(await closed.approve(host: "d.com") == false && model.workflowApproval == nil)
        #expect(await (AskWorkflowLauncherActionHost(model: model) {}).approve(host: "d.com") == false,
                "no workflow to remember it for")
    }

    @Test func `run keyword chains workflows and stops A loop`() async throws {
        try await withPasteboard { _ in
            let workflows = try AskWorkflowFixture()
            try workflows.write("first", manifest: AskWorkflowFixture.inline(
                "first", keyword: "aa", script: "print -r -- \"A:$1\"",
                extra: ["output": ["display": "text", "close": true,
                                   "onSuccess": [["action": "runKeyword", "keyword": "bb", "argument": "{output}"]]]]
            ))
            try workflows.write("second", manifest: AskWorkflowFixture.inline(
                "second", keyword: "bb", script: "print -r -- \"B:$1\"",
                extra: ["output": ["display": "text",
                                   "onSuccess": [["action": "runKeyword", "keyword": "aa", "argument": "{output}"]]]]
            ))
            let launcher = try await launcher(workflows, ids: ["first", "second"])
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await enter("aa go", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output?.body == "B:A:go" }
            #expect(model.plugins.keyword?.keyword == "bb" && model.launcherDraft.text == "A:go")
            #expect(model.plugins.request?.chain == ["aa"])
            #expect(launcher.dismissed == 0, "a run handed to another keyword does not close the launcher")
            try await waitFor { model.currentWorkflowActions != nil }
            #expect(model.currentWorkflowActions?.outcomes.first?.status
                == .failed(L("ask.workflow.action.loop", "aa → bb → aa")))
            #expect(model.plugins.output?.body == "B:A:go", "the loop stopped at bb")
            // Typing something else starts a chain of its own.
            try await enter("!", into: launcher)
            try await waitFor { model.plugins.request?.text == "A:go!" }
            #expect(model.plugins.request?.chain == [])
            #expect(!model.runLauncherKeyword("nope", argument: "", chain: []))
        }
    }

    @Test func `return on an image copies the image`() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            let folder = try workflows.write("qr", manifest: AskWorkflowFixture.inline(
                "qr", keyword: "qr", script: "print -r -- code.png", output: "image"
            ))
            try askWorkflowTestPNG(width: 50, height: 50).write(to: folder.appendingPathComponent("code.png"))
            let launcher = try await launcher(workflows, ids: ["qr"])
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await enter("qr x", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output?.image != nil }
            #expect(AskPluginResultsView.hint(for: AskPluginDisplay(title: "", symbol: "", phase: model.plugins.phase))
                .contains(L("ask.plugin.action.copyImage")))
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.data(forType: .png) != nil && launcher.dismissed == 1)
            #expect(pasteboard.string(forType: .fileURL)?.hasSuffix("code.png") == true)
        }
    }
}
