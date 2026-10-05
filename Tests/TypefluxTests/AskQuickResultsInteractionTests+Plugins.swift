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
            try await settle { model.plugins.output != nil }
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
            #expect(model.launcherKeywords == AskTranslatePlugin.keywords)
            #expect(model.makeLauncherPlugins().map(\.id) == ["translate"])
        }
    }
}
