import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Esc layers, Return on the highlighted row, "Ask AI" only with something to
/// ask, and the results area settling to its rows, in the real launcher.
extension AskQuickResultsInteractionTests {
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "timed out")
    }

    private func replaceText(_ text: String, in launcher: Launcher) {
        launcher.editor.selectAll(nil)
        launcher.editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func escapeLeavesKeywordModeKeepingTheTextBeforeItCloses() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            for char in "fy hello" {
                launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            try await waitFor { model.plugins.output?.body == "[zh-Hans] hello" }
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 0, "the first Esc only leaves keyword mode")
            #expect(!model.plugins.isActive && model.launcherDraft.text == "hello")
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 1)
            #expect(model.launcherDraft.text == "hello", "closing keeps the draft for next time")
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func returnEntersTheHighlightedKeywordHint() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "history")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await waitFor { model.plugins.hint?.pluginID == AskHistoryPlugin.id }
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.keyword?.pluginID == AskHistoryPlugin.id, "Return does what the highlighted row says")
            #expect(launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func anEmptyKeywordOffersNoAskAIRow() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(Self.returnKey)
            try await waitFor { model.plugins.output?.items.isEmpty == false }
            let count = try #require(model.plugins.output?.items.count)
            try await launcher.press(Self.up)
            #expect(model.plugins.output?.selectedItem == count - 1, "↑ wraps within the list instead of an empty Ask AI")
            try await launcher.press(Self.returnKey, .command)
            #expect(model.plugins.isActive && launcher.dismissed == 0)
            #expect(await launcher.fixture.api.sends.isEmpty, "⌘↩ has nothing to ask")
            replaceText("gh", in: launcher)
            try await waitFor { model.plugins.output?.original == "gh" }
            try await launcher.press(Self.up)
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1, "with text typed, Ask AI is back and takes Return")
        }
    }

    @Test func aShorterListSettlesOnceTypingPauses() async throws {
        try await withPasteboard { _ in
            let launcher = try await Launcher(text: "prefix")
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await launcher.press(Self.returnKey)
            try await waitFor { (model.plugins.output?.items.count ?? 0) >= AskPluginResultsView.maximumVisibleItems }
            try await Task.sleep(for: .milliseconds(50))
            let tall = try #require(launcher.heights.last)
            replaceText("gh", in: launcher)
            try await waitFor { model.plugins.output?.items.count == 1 }
            try await Task.sleep(for: .milliseconds(50))
            let typing = try #require(launcher.heights.last)
            #expect(typing < tall, "the kept space is capped while typing")
            try await Task.sleep(for: AskLauncherHeightReserve.settleDelay + .milliseconds(450))
            let settled = try #require(launcher.heights.last)
            #expect(abs(typing - settled - AskLauncherHeightReserve.maximumSlack) <= 1,
                    "after the pause the panel fits the one row")
        }
    }
}
