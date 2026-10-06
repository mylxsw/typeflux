import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Keyword plugins in the real launcher, driven by key presses. They live in
/// the quick results interaction suite: both swap the copy pasteboard, so they
/// must take turns.
extension AskQuickResultsInteractionTests {
    /// Translation with test engines: on this Mac or by the AI, text always English.
    @MainActor final class Translation {
        let device = AskTestTranslationEngine()
        let ai = AskTestTranslationEngine()
        var delivered: [String] = []
        var spoken: [String] = []
        var deliveryFails = false

        func install(in model: AskConversationModel) {
            let plugin = AskTranslatePlugin(onDevice: device, ai: ai, aiName: { "test-model" },
                                            detector: AskTestLanguageDetector(language: "en"))
            model.plugins = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
            model.plugins.debounce = .milliseconds(10)
            model.deliverText = { [unowned self] text in
                if deliveryFails { throw TextDeliveryError.noInput }
                delivered.append(text)
            }
            model.speak = { [unowned self] text, _ in spoken.append(text) }
        }
    }

    static let backspace: UInt16 = 51

    private func type(_ text: String, into launcher: Launcher) async throws {
        for char in text {
            launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), "timed out")
    }

    @Test func aKeywordBecomesAChipAndTypedTextTranslatesWhileTyping() async throws {
        try await withPasteboard { pasteboard in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy ", into: launcher)
            #expect(model.plugins.isActive)
            #expect(model.launcherDraft.text.isEmpty, "the keyword left the editor for its chip")
            try await type("hello", into: launcher)
            // Under load a result for "hell" may land first; wait for the whole word.
            try await settle { model.plugins.output?.body == "[zh-Hans] hello" }
            #expect(model.plugins.output?.body == "[zh-Hans] hello", "English text goes into the second language")
            #expect(translation.ai.requests.isEmpty)
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "[zh-Hans] hello")
            #expect(launcher.dismissed == 1)
            #expect(!model.plugins.isActive && model.launcherDraft.text.isEmpty)
        }
    }

    @Test func withNothingTypedTheSelectionIsTranslatedOnReturnAndWrittenBack() async throws {
        try await withPasteboard { pasteboard in
            let translation = Translation()
            let launcher = try await Launcher(text: "", selection: "Selected words", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy ", into: launcher)
            try await settle { if case .ready = model.plugins.phase { true } else { false } }
            #expect(translation.device.requests.isEmpty, "the selection waits for Return")
            #expect(model.plugins.request?.origin == .selection)
            try await launcher.press(Self.returnKey)
            try await settle { model.plugins.output != nil }
            #expect(model.plugins.output?.body == "[zh-Hans] Selected words")
            try await launcher.press(Self.returnKey, .option)
            #expect(launcher.dismissed == 1)
            try await settle { !translation.delivered.isEmpty }
            #expect(translation.delivered == ["[zh-Hans] Selected words"])
            #expect(pasteboard.string(forType: .string) == nil)
        }
    }

    @Test func tabChangesTheLanguageAndCommandRAsksTheAI() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy hi", into: launcher)
            try await settle { model.plugins.output != nil }
            try await launcher.press(Self.tab)
            try await settle { model.plugins.output?.body == "[ja] hi" }
            try await launcher.press(Self.tab, .shift)
            try await settle { model.plugins.output?.body == "[zh-Hans] hi" }
            try await launcher.press(15, .command)
            try await settle { model.plugins.output?.sourceIsAI == true }
            #expect(translation.ai.requests.count == 1)
            try await launcher.press(2, .command)
            #expect(model.plugins.comparing)
            #expect(launcher.dismissed == 0)
        }
    }

    @Test func backspaceTurnsTheChipBackIntoText() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy ", into: launcher)
            #expect(model.plugins.isActive)
            try await launcher.press(Self.backspace)
            #expect(!model.plugins.isActive)
            #expect(model.launcherDraft.text == "fy")
            try await settle { model.plugins.hint != nil }
            try await launcher.press(Self.tab)
            #expect(model.plugins.isActive, "⇥ on the hint enters the keyword again")
        }
    }

    @Test func aLoneKeywordStillAsksTheAIOnReturn() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            try await type("fy", into: launcher)
            #expect(launcher.fixture.model.plugins.hint != nil)
            try await launcher.press(Self.returnKey)
            #expect(try await launcher.sentCount() == 1)
        }
    }

    @Test func commandReturnTakesTheResultToTheAI() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy hello", into: launcher)
            try await settle { model.plugins.output != nil }
            try await launcher.press(Self.returnKey, .command)
            #expect(try await launcher.sentCount() == 1)
            #expect(await launcher.fixture.api.sends.first?.text.contains("[zh-Hans] hello") == true)
            #expect(!model.plugins.isActive)
        }
    }

    @Test func escapeCancelsARunThenCloses() async throws {
        try await withPasteboard { _ in
            let translation = Translation()
            translation.device.delay = .milliseconds(500)
            let launcher = try await Launcher(text: "", selection: "Words", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("fy ", into: launcher)
            try await settle { if case .ready = model.plugins.phase { true } else { false } }
            try await launcher.press(Self.returnKey)
            #expect(model.plugins.isRunning)
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 0)
            if case .ready = model.plugins.phase {} else { Issue.record("esc returns to ready") }
            try await launcher.press(Self.escape)
            #expect(launcher.dismissed == 1)
        }
    }

    @Test func modelActionsSpeakCompareFoldAndRecoverFromFailedWriteBack() async throws {
        try await withPasteboard { pasteboard in
            let translation = Translation()
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            let model = fixture.model
            translation.install(in: model)
            #expect(model.performPluginAction(AskPluginAction(kind: .speak("hola", language: "es"), title: "", symbol: "")) == .stay)
            #expect(translation.spoken == ["hola"])
            #expect(model.performPluginAction(AskPluginAction(kind: .compare, title: "", symbol: "")) == .stay)
            #expect(model.plugins.comparing)
            _ = model.plugins.detect(in: "fy hello")
            model.launcherDraft.text = "hello"
            model.foldLauncherKeyword()
            #expect(model.launcherDraft.text == "fy hello" && !model.plugins.isActive)
            model.foldLauncherKeyword()
            #expect(model.launcherDraft.text == "fy hello", "nothing to fold outside keyword mode")
            translation.deliveryFails = true
            #expect(model.performPluginAction(AskPluginAction(kind: .writeBack("texto"), title: "", symbol: "")) == .close)
            try await settle { pasteboard.string(forType: .string) == "texto" }
            #expect(model.commandFeedback == L("ask.plugin.writeBack.failed"))
            model.deliverText = nil
            model.writeBack("plain")
            #expect(pasteboard.string(forType: .string) == "plain")
            var opened: [URL] = []
            model.openURL = { opened.append($0) }
            let link = try #require(URL(string: "https://example.com/?q=x"))
            #expect(model.performPluginAction(AskPluginAction(kind: .open(link), title: "", symbol: "")) == .close)
            #expect(opened == [link])
            model.copyPluginText("kept")
            #expect(pasteboard.string(forType: .string) == "kept" && model.commandFeedback == L("ask.plugin.copied"))
            #expect(model.launcherKeywords == AskPluginRegistry.defaultKeywords)
            #expect(model.makeLauncherPlugins().map(\.id) == AskPluginRegistry.pluginIDs)
        }
    }

    // MARK: - Web search and AI prompts

    @Test func aWebSearchOpensOnReturnAndCommandCCopiesItsLink() async throws {
        try await withPasteboard { pasteboard in
            final class Opened { var urls: [URL] = [] }
            let opened = Opened()
            let launcher = try await Launcher(text: "") { model in
                model.plugins = AskPluginSession(plugins: [AskWebSearchPlugin()]) { AskWebSearchPlugin.keywords }
                model.openURL = { opened.urls.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("g swift actors", into: launcher)
            try await settle { model.plugins.isPlanCurrent && model.plugins.plan?.action(for: .enter) != nil }
            try await launcher.press(8, .command)
            #expect(pasteboard.string(forType: .string) == "https://www.google.com/search?q=swift%20actors")
            #expect(launcher.dismissed == 0, "⌘C keeps the launcher open")
            try await launcher.press(Self.tab)
            try await settle { model.plugins.isPlanCurrent && model.plugins.plan?.title.contains(L("ask.plugin.web.baidu")) == true }
            try await launcher.press(Self.returnKey)
            #expect(opened.urls.map(\.absoluteString) == ["https://www.baidu.com/s?wd=swift%20actors"])
            #expect(launcher.dismissed == 1)
            #expect(!model.plugins.isActive && model.launcherDraft.text.isEmpty)
            #expect(await launcher.fixture.api.sends.isEmpty)
        }
    }

    @Test func anAIPromptStreamsOnReturnThenCopiesAndRegenerates() async throws {
        try await withPasteboard { pasteboard in
            let generator = AskTestTextGenerator()
            generator.pieces = ["Pol", "ished"]
            generator.delay = .milliseconds(80)
            let launcher = try await Launcher(text: "") { model in
                let plugin = AskPromptPlugin(generator: generator, modelName: { "m" })
                model.plugins = AskPluginSession(plugins: [plugin]) { AskPromptPlugin.keywords }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            try await type("rw teh text", into: launcher)
            try await settle { if case .ready = model.plugins.phase { true } else { false } }
            #expect(generator.prompts.isEmpty, "nothing goes to the model before Return")
            try await launcher.press(Self.returnKey)
            try await settle { model.plugins.partial?.body == "Pol" }
            try await settle { model.plugins.output != nil }
            #expect(model.plugins.output?.body == "Polished")
            #expect(generator.prompts.first?.user.hasSuffix("teh text") == true)
            // The editor has nothing selected, so copying copies the result and stays.
            launcher.editor.copy(nil)
            #expect(pasteboard.string(forType: .string) == "Polished")
            #expect(launcher.dismissed == 0)
            generator.pieces = ["Again"]
            try await launcher.press(15, .command)
            try await settle { model.plugins.output?.body == "Again" }
            #expect(generator.prompts.count == 2)
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "Again")
            #expect(launcher.dismissed == 1)
        }
    }

    // MARK: - Workflows

    @Test func aWorkflowRunsOnReturnAndOneThatOnlyActsClosesTheLauncher() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.write("rev", manifest: AskWorkflowFixture.inline("rev", keyword: "rv", script: "print -r -- \"$1\" | rev"))
            try workflows.write("touch", manifest: AskWorkflowFixture.inline("touch", keyword: "tc", script: "touch done",
                                                                             output: "none"))
            workflows.store.reload()
            workflows.store.trust("rev")
            workflows.store.trust("touch")
            let launcher = try await Launcher(text: "") { model in model.workflows = workflows.store }
            defer { launcher.close() }
            let model = launcher.fixture.model
            // Read the login shell's PATH up front, so the runs below only time the scripts.
            _ = await AskWorkflowPath.searchPath()
            await model.refreshLauncherWorkflows()
            #expect(model.launcherKeywords.contains { $0.keyword == "rv" })
            try await type("rv hello", into: launcher)
            try await settle { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            for _ in 0 ..< 1000 where model.plugins.output == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.plugins.output?.body == "olleh")
            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "olleh" && launcher.dismissed == 1)
            try await type("tc go", into: launcher)
            try await settle { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            for _ in 0 ..< 1000 where launcher.dismissed < 2 { try await Task.sleep(for: .milliseconds(10)) }
            #expect(launcher.dismissed == 2)
            #expect(FileManager.default.fileExists(atPath: workflows.root.appendingPathComponent("touch/done").path))
            #expect(!model.plugins.isActive && model.launcherDraft.text.isEmpty)
        }
    }

    @Test func aWorkflowsActionsRunAfterItAndCopyingCanBeUndone() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.write("fx", manifest: AskWorkflowFixture.inline("fx", keyword: "fx", script: "print -r -- \"$1 ok\"\nprint second",
                                                                          extra: ["output": [
                "display": "text",
                "onSuccess": [["action": "copy", "value": "{output.line1}"],
                              ["action": "notify", "title": "FX", "body": "{output.lastLine}"],
                              ["action": "hud", "text": "Saved"]]
            ]]))
            workflows.store.reload()
            workflows.store.trust("fx")
            var notified: [String] = []
            let launcher = try await Launcher(text: "") { model in
                model.workflows = workflows.store
                model.notifyUser = { title, body in notified.append(title + "|" + body); return true }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            _ = await AskWorkflowPath.searchPath()
            await model.refreshLauncherWorkflows()
            pasteboard.clearContents()
            pasteboard.setString("before", forType: .string)
            try await type("fx 100", into: launcher)
            try await settle { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await settle { model.currentWorkflowActions != nil }
            #expect(model.plugins.output?.body == "100 ok\nsecond")
            #expect(pasteboard.string(forType: .string) == "100 ok")
            #expect(notified == ["FX|second"])
            let state = try #require(model.currentWorkflowActions)
            #expect(state.outcomes.count == 3 && state.canUndo && !state.failed)
            #expect(state.summary.contains("Saved"), "the bottom-bar note is part of the summary")
            #expect(launcher.dismissed == 0, "the result stays")
            try await launcher.press(6, .command)
            #expect(pasteboard.string(forType: .string) == "before", "⌘Z put the clipboard back")
            #expect(model.currentWorkflowActions?.undone == true && model.currentWorkflowActions?.canUndo == false)
            #expect(!model.undoWorkflowCopy(), "only once")
        }
    }

    @Test func aWorkflowThatClosesRunsItsActionsFirstAndFailuresRunTheirOwn() async throws {
        try await withPasteboard { pasteboard in
            let workflows = try AskWorkflowFixture()
            try workflows.write("uuid", manifest: AskWorkflowFixture.inline("uuid", keyword: "uu", script: "print -r -- abc",
                                                                            extra: ["output": [
                "display": "none", "onSuccess": [["action": "copy", "value": "{output}"],
                                                 ["action": "writeBack", "value": "{output}"],
                                                 ["action": "hud", "text": "after"]]
            ]]))
            try workflows.write("bad", manifest: AskWorkflowFixture.inline("bad", keyword: "zf", script: "print -u2 oops; exit 3",
                                                                           extra: ["output": [
                "display": "text", "onFailure": [["action": "notify", "body": "{error}"]]
            ]]))
            workflows.store.reload()
            workflows.store.trust("uuid")
            workflows.store.trust("bad")
            var notices: [String] = []
            var notified: [String] = []
            var delivered: [String] = []
            let launcher = try await Launcher(text: "") { model in
                model.workflows = workflows.store
                model.passiveNotice = { notices.append($0) }
                model.notifyUser = { _, body in notified.append(body); return false }
                model.deliverText = { delivered.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            _ = await AskWorkflowPath.searchPath()
            await model.refreshLauncherWorkflows()
            try await type("uu go", into: launcher)
            try await settle { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await settle { launcher.dismissed == 1 && notices == ["after"] }
            #expect(pasteboard.string(forType: .string) == "abc")
            try await settle { delivered == ["abc"] }
            #expect(launcher.dismissed == 1, "closed once, by writing back")
            #expect(!model.plugins.isActive)
            try await type("zf go", into: launcher)
            try await settle { model.plugins.isPlanCurrent }
            try await launcher.press(Self.returnKey)
            try await settle { model.currentWorkflowActions != nil }
            if case .failed = model.plugins.phase {} else { Issue.record("the error card shows") }
            #expect(notified.first?.contains("oops") == true && notified.first?.contains("3") == true)
            let state = try #require(model.currentWorkflowActions)
            #expect(state.outcomes.first?.status == .fellBack(L("ask.workflow.action.notifyDenied")))
            #expect(!state.canUndo && launcher.dismissed == 1)
        }
    }
}
