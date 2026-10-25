import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
struct AskWordBookDictTests {
    private let dict = AskTranslatePlugin.keywords.first { $0.keyword == "dict" }!

    private func plugin(_ store: SQLiteAskWordBookStore?, local: Bool = true) -> AskTranslatePlugin {
        AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: local), ai: AskTestTranslationEngine(),
                           dictionary: AskTestWordLookup(answer: .card(wordBookCard)), wordBook: store,
                           aiName: { "gpt-test" }, detector: AskTestLanguageDetector(language: "en"))
    }

    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument,
                         options: [String: String]? = nil) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: dict, options: options ?? dict.options,
                         interfaceLanguage: .simplifiedChinese)
    }

    @Test func `dict and ci dian open the word book`() {
        let keywords = AskTranslatePlugin.keywords.filter { AskTranslatePlugin.opensWordBook($0.options) }
        #expect(keywords.map(\.keyword) == ["dict", "词典"])
        #expect(!AskTranslatePlugin.opensWordBook(AskTranslatePlugin.keywords[0].options))
        #expect(plugin(nil).chipDetail(for: dict, language: .english) == L("ask.wordBook.title"))
    }

    @Test func `opens without querying regardless of input`() async throws {
        let translate = plugin(nil, local: false)
        for text in ["", "hello"] {
            for origin in [AskPluginRequest.Origin.argument, .selection] {
                let input = request(text, origin: origin)
                let plan = await translate.plan(input)
                #expect(plan.mode == .onSubmit)
                #expect(plan.action(for: .enter)?.kind == .openWordBook(key: nil))
                #expect(plan.values.isEmpty)
                await #expect(throws: CancellationError.self) {
                    try await translate.run(input, plan: plan)
                }
            }
        }
    }
}

@Suite(.exclusiveUIState)
struct AskWordBookDictSettingsTests {
    @Test func `the editor switches between translating and the word book`() throws {
        let dict = try #require(AskTranslatePlugin.keywords.first { $0.keyword == "dict" })
        var draft = AskKeywordDraft(editing: dict)
        #expect(draft.opensWordBook && draft.displayName == L("ask.wordBook.title"))
        #expect(draft.result().options == [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction])
        draft.opensWordBook = false
        draft.target = "ja"
        #expect(draft.result().options == [AskTranslatePlugin.targetOption: "ja"])
        #expect(draft.displayName.contains(L("ask.plugin.translate.title")))

        var fresh = AskKeywordDraft(adding: .translate)
        #expect(!fresh.opensWordBook)
        fresh.keyword = "wb"
        fresh.target = "ja"
        fresh.opensWordBook = true
        let saved = fresh.result()
        #expect(saved.options == [AskTranslatePlugin.actionOption: AskTranslatePlugin.wordBookAction],
                "a word book keyword keeps no target")
        #expect(AskTranslatePlugin.opensWordBook(saved.options))
    }

    @Test func `the list names and describes it`() throws {
        let dict = try #require(AskTranslatePlugin.keywords.first { $0.keyword == "dict" })
        #expect(AskKeywordListPresentation.name(of: dict) == L("ask.wordBook.title"))
        #expect(AskKeywordListPresentation.summary(of: dict, interface: .english, secondLanguage: "zh-Hans")
            == L("ask.settings.keywords.summary.wordBook"))
        #expect(AskKeywordListPresentation.name(of: AskTranslatePlugin.keywords[0]) == L("ask.plugin.translate.title"))
    }
}

extension AskQuickResultsInteractionTests {
    @Test func `dict with A word opens the word book on return`() async throws {
        try await withPasteboard { _ in
            let translation = WordBookTranslation()
            var opened: [String?] = []
            let launcher = try await Launcher(text: "") { model in
                translation.install(in: model)
                model.openWordBook = { opened.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            for char in "dict gregarious" {
                launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0 ..< 400 where !model.plugins.isPlanCurrent { try await Task.sleep(for: .milliseconds(5)) }
            try await launcher.press(Self.returnKey)
            #expect(opened.count == 1 && opened[0] == nil)
            #expect(launcher.dismissed == 1)
            #expect(try translation.store.count(.all) == 0, "the launcher keeps nothing; the window does")
        }
    }
}
