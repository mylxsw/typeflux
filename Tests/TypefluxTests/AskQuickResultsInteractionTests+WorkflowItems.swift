import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Workflow lists in the real launcher, driven by key presses: the arrows choose a
/// row, Return and ⌥↩ use it, ⇥ goes one level deeper and `variables` come back.
extension AskQuickResultsInteractionTests {
    /// Rows A (copied) and B (completes to "deeper"), then an invalid one; titles
    /// say what the script got, so a rerun shows.
    static let listScript = #"""
    print -r -- "{\"items\": [{\"uid\": \"a\", \"title\": \"A:$1:$TYPEFLUX_OPTION_SEEN\", \"arg\": \"alpha\", \"action\": \"copy\"},"
    print -r -- "{\"uid\": \"b\", \"title\": \"B\", \"arg\": \"beta\", \"autocomplete\": \"deeper\"},"
    print -r -- "{\"uid\": \"c\", \"title\": \"Sign in first\", \"valid\": false}], \"variables\": {\"seen\": \"yes\"}}"
    """#

    private func typeText(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "timed out")
    }

    private func listLauncher(prepare: @escaping (AskConversationModel) -> Void = { _ in }) async throws
        -> (Launcher, AskWorkflowFixture) {
        let workflows = try AskWorkflowFixture()
        try workflows.write("list", manifest: AskWorkflowFixture.inline("list", keyword: "ls", script: Self.listScript,
                                                                        output: "items"))
        workflows.store.reload()
        workflows.store.trust("list")
        let launcher = try await Launcher(text: "") { model in
            model.workflows = workflows.store
            prepare(model)
        }
        _ = await AskWorkflowPath.searchPath()
        await launcher.fixture.model.refreshLauncherWorkflows()
        return (launcher, workflows)
    }

    @Test func `a workflow list is chosen with the arrows and goes deeper with tab`() async throws {
        try await withPasteboard { pasteboard in
            let (launcher, workflows) = try await listLauncher()
            defer { launcher.close(); _ = workflows }
            let model = launcher.fixture.model
            try await typeText("ls x", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output?.items.count == 3 }
            #expect(model.plugins.output?.items.map(\.title) == ["A:x:", "B", "Sign in first"])
            #expect(try AskPluginResultsView.hint(for: #require(launcherDisplay(model)))
                .contains(L("ask.plugin.action.copy")))
            try await launcher.press(Self.down)
            #expect(model.plugins.output?.selectedItem == 1)
            try await launcher.press(20, .command) // The invalid third row cannot execute.
            #expect(model.plugins.output?.selectedItem == 1)
            #expect(
                launcher.dismissed == 0 && pasteboard.string(forType: .string) == nil,
                "an invalid row does nothing"
            )
            try await launcher.press(Self.down)
            try await launcher.press(Self.down)
            #expect(model.plugins.output?.selectedItem == 0, "past Ask AI the arrows come back to the first row")
            try await launcher.press(Self.up)
            try await launcher.press(Self.up)
            #expect(model.plugins.output?.selectedItem == 1, "up from the first row skips the invalid last row")
            #expect(model.plugins.output?.selected?.autocomplete == "deeper")
            try await launcher.press(Self.tab)
            try await waitFor { model.plugins.output?.items.first?.title == "A:deeper:yes" }
            #expect(model.launcherDraft.text == "deeper", "the completion went into the editor")
            #expect(model.plugins.output?.items.first?.title == "A:deeper:yes", "variables came back as options")
            try await launcher.press(8, .command)
            #expect(pasteboard.string(forType: .string) == "alpha" && launcher.dismissed == 0, "⌘C copies and stays")
            pasteboard.clearContents()
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "alpha" && launcher.dismissed == 1)
        }
    }

    @Test func `option return writes A row back and rows open reveal and run`() async throws {
        try await withPasteboard { _ in
            var delivered: [String] = []
            var opened: [(URL, String)] = []
            var revealed: [URL] = []
            let (launcher, workflows) = try await listLauncher { model in
                model.deliverText = { delivered.append($0) }
                model.openFileInApplication = { url, app in opened.append((url, app)); return app == "Zed" }
                model.revealFile = { revealed.append($0) }
            }
            defer { launcher.close(); _ = workflows }
            let model = launcher.fixture.model
            var links: [URL] = []
            model.openURL = { links.append($0) }
            try await typeText("ls x", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output?.items.count == 3 }
            try await launcher.press(Self.down)
            try await launcher.press(Self.returnKey, .option)
            try await waitFor { delivered == ["beta"] }
            #expect(launcher.dismissed == 1)
            let file = URL(fileURLWithPath: "/tmp/p")
            #expect(model
                .performPluginAction(.init(kind: .openIn(file, application: "Zed"), title: "", symbol: "")) == .close)
            #expect(model
                .performPluginAction(.init(kind: .openIn(file, application: "Nope"), title: "", symbol: "")) == .close)
            #expect(opened.map(\.1) == ["Zed", "Nope"] && links == [file], "without the app it opens as Finder would")
            #expect(model.performPluginAction(.init(kind: .reveal(file), title: "", symbol: "")) == .close)
            #expect(revealed == [file])
        }
    }

    @Test func `a markdown workflow shows its card and copies the source`() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.write("md", manifest: AskWorkflowFixture.inline(
                "md", keyword: "md",
                script: "print -r -- '# Title'; print -r -- '| a | b |'; print -r -- '|---|---|'; print -r -- '| 1 | 2 |'",
                output: "markdown"
            ))
            workflows.store.reload()
            workflows.store.trust("md")
            let launcher = try await Launcher(text: "") { model in model.workflows = workflows.store }
            defer { launcher.close() }
            let model = launcher.fixture.model
            _ = await AskWorkflowPath.searchPath()
            await model.refreshLauncherWorkflows()
            try await typeText("md go", into: launcher)
            try await waitFor { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output != nil }
            let output = try #require(model.plugins.output)
            #expect(output.markdown && output.body.hasPrefix("# Title"))
            let display = try #require(launcherDisplay(model))
            #expect(AskPluginResultsView.mainHeight(display) > AskPluginResultsView.cardHeight(
                output: AskPluginOutput(body: "x", original: "", meta: [], source: "", actions: []), failure: nil,
                comparing: false
            ), "a heading and a table take more room than a line")
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == output.body && launcher.dismissed == 1)
        }
    }

    private func launcherDisplay(_ model: AskConversationModel) -> AskPluginDisplay? {
        guard let plugin = model.plugins.plugin else { return nil }
        return AskPluginDisplay(title: plugin.title, symbol: plugin.symbol, phase: model.plugins.phase)
    }
}
