import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask dict keyword")
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

    @Test func dictAndCiDianOpenTheWordBook() {
        let keywords = AskTranslatePlugin.keywords.filter { AskTranslatePlugin.opensWordBook($0.options) }
        #expect(keywords.map(\.keyword) == ["dict", "词典"])
        #expect(!AskTranslatePlugin.opensWordBook(AskTranslatePlugin.keywords[0].options))
        #expect(plugin(nil).chipDetail(for: dict, language: .english) == L("ask.wordBook.title"))
    }

    @Test func aloneItOffersTheWordBookFirstThenRecentWords() async throws {
        let store = makeTestWordBook()
        let saved = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard)
        store.record(saved, at: Date(), counts: true)
        let translate = plugin(store)
        let plan = await translate.plan(request(""))
        #expect(plan.mode == .live && plan.title == L("ask.wordBook.title"))
        let output = try await translate.run(request(""), plan: plan)
        #expect(output.items.map(\.id) == [AskTranslatePlugin.openAllItem, saved.key])
        #expect(output.items[0].actions.first?.kind == .openWordBook(key: nil))
        #expect(output.items[1].actions.first { $0.shortcut == .enter }?.kind == .openWordBook(key: saved.key))
        #expect(output.items.allSatisfy { $0.actions.first { $0.shortcut == .enter }?.title == L("ask.plugin.action.open") })
        #expect(output.items[1].actions.contains { $0.shortcut == .commandS })
    }

    @Test func aWordPreviewsOnThisMacAndReturnLooksItUp() async throws {
        let store = makeTestWordBook()
        let translate = plugin(store)
        let word = request(" gregarious ")
        let plan = await translate.plan(word)
        #expect(plan.mode == .live && plan.title == L("ask.wordBook.dict.title"))
        #expect(plan.values["engine"] == "device")
        #expect(plan.action(for: .enter)?.kind == .lookUpInWordBook("gregarious"))
        let output = try await translate.run(word, plan: plan)
        #expect(output.body == "[zh-Hans]  gregarious ")
        #expect(output.source == L("ask.plugin.source.device") && !output.sourceIsAI)
        #expect(output.action(for: .enter)?.kind == .lookUpInWordBook("gregarious"))
        #expect(output.action(for: .commandC)?.kind == .copy("[zh-Hans]  gregarious "))
        #expect(output.wordBook == nil, "the window keeps the word, not the preview")
        #expect(output.note == L("ask.wordBook.dict.hint"))
    }

    @Test func aKeptCardPreviewsFromTheBook() async throws {
        let store = makeTestWordBook()
        store.record(AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard),
                     at: Date(), counts: true)
        let translate = plugin(store, local: false)
        let word = request("serendipity")
        let plan = await translate.plan(word)
        #expect(plan.mode == .live && plan.values["engine"] == "book")
        let output = try await translate.run(word, plan: plan)
        #expect(output.body == "n. 机缘巧合；意外的好运  adj. 偶然的")
        #expect(output.source == L("ask.plugin.source.wordBook"))
    }

    @Test func withoutAPreviewOrForTheSelectionReturnStillLooksItUp() async throws {
        let translate = plugin(makeTestWordBook(), local: false)
        let typed = await translate.plan(request("gregarious"))
        #expect(typed.mode == .onSubmit && typed.values["engine"] == "none")
        #expect(typed.action(for: .enter)?.kind == .lookUpInWordBook("gregarious"))
        let selected = await plugin(makeTestWordBook()).plan(request("ubiquitous", origin: .selection))
        #expect(selected.mode == .onSubmit)
        #expect(selected.action(for: .enter)?.kind == .lookUpInWordBook("ubiquitous"))
    }
}

@Suite("Ask dict keyword in settings")
struct AskWordBookDictSettingsTests {
    @Test func theEditorSwitchesBetweenTranslatingAndTheWordBook() {
        let dict = AskTranslatePlugin.keywords.first { $0.keyword == "dict" }!
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

    @Test func theListNamesAndDescribesIt() {
        let dict = AskTranslatePlugin.keywords.first { $0.keyword == "dict" }!
        #expect(AskKeywordListPresentation.name(of: dict) == L("ask.wordBook.title"))
        #expect(AskKeywordListPresentation.summary(of: dict, interface: .english, secondLanguage: "zh-Hans")
            == L("ask.settings.keywords.summary.wordBook"))
        #expect(AskKeywordListPresentation.name(of: AskTranslatePlugin.keywords[0]) == L("ask.plugin.translate.title"))
    }
}

extension AskQuickResultsInteractionTests {
    @Test func dictWithAWordOpensTheWordBookOnReturn() async throws {
        try await withPasteboard { _ in
            let translation = WordBookTranslation()
            var looked: [String] = []
            let launcher = try await Launcher(text: "") { model in
                translation.install(in: model)
                model.lookUpInWordBook = { looked.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            for char in "dict gregarious" {
                launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0 ..< 400 where !model.plugins.isPlanCurrent { try await Task.sleep(for: .milliseconds(5)) }
            try await launcher.press(Self.returnKey)
            #expect(looked == ["gregarious"])
            #expect(launcher.dismissed == 1)
            #expect(translation.store.count(.all) == 0, "the launcher keeps nothing; the window does")
        }
    }
}
