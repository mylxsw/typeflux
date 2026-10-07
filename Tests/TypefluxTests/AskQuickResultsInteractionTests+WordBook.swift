import AppKit
import Foundation
import Testing
@testable import Typeflux

/// The word book from the real launcher: ⌘S stars the word on screen, and using
/// a result keeps the word it looked up.
extension AskQuickResultsInteractionTests {
    static let sKey: UInt16 = 1

    @MainActor final class WordBookTranslation {
        let store = makeTestWordBook()
        let device = AskTestTranslationEngine()

        func install(in model: AskConversationModel) {
            model.wordBook = AskWordBookRecorder(store: store)
            let plugin = AskTranslatePlugin(onDevice: device, ai: AskTestTranslationEngine(), wordBook: store,
                                            aiName: { "test-model" }, detector: AskTestLanguageDetector(language: "en"))
            model.plugins = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
            model.plugins.debounce = .milliseconds(10)
            model.connectWordBook(to: model.plugins)
        }
    }

    @Test func commandSStarsTheWordAndUsingTheResultKeepsIt() async throws {
        try await withPasteboard { pasteboard in
            let translation = WordBookTranslation()
            let launcher = try await Launcher(text: "", prepare: translation.install)
            defer { launcher.close() }
            let model = launcher.fixture.model
            for char in "fy resilient" {
                launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0 ..< 400 where model.plugins.output?.original != "resilient" {
                try await Task.sleep(for: .milliseconds(5))
            }
            let lookup = try #require(model.plugins.output?.wordBook)
            #expect(translation.store.count(.all) == 0, "a word typed on the fly waits to settle")

            try await launcher.press(Self.sKey, .command)
            #expect(translation.store.entry(forKey: lookup.key)?.isStarred == true)
            #expect(model.plugins.output?.starred == true)
            #expect(launcher.dismissed == 0, "starring keeps the launcher open")

            try await launcher.press(Self.sKey, .command)
            #expect(translation.store.entry(forKey: lookup.key)?.isStarred == false)
            #expect(model.plugins.output?.starred == false)

            try await launcher.press(Self.returnKey)
            #expect(pasteboard.string(forType: .string) == "[zh-Hans] resilient")
            #expect(launcher.dismissed == 1)
            #expect(translation.store.entry(forKey: lookup.key)?.lookupCount == 1, "counted once in this session")
        }
    }
}
