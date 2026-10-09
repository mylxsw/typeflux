import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private let serendipity = AskWordCard(
    headword: "serendipity",
    phonetics: [.init(label: "UK", text: "/ˌserənˈdɪpəti/"), .init(label: "US", text: "/ˌserənˈdɪpəti/")],
    senses: [.init(pos: "n.", meanings: ["机缘巧合", "意外的好运"])],
    forms: [.init(label: "复数", value: "serendipities")],
    examples: [.init(source: "It was pure **serendipity**.", target: "这纯属机缘巧合。")],
    synonyms: ["chance", "fluke"]
)

private let serendipityJSON = """
{"kind":"word","headword":"serendipity",
 "phonetics":[{"label":"UK","text":"/ˌserənˈdɪpəti/"},{"label":"US","text":"/ˌserənˈdɪpəti/"}],
 "senses":[{"pos":"n.","meanings":["机缘巧合","意外的好运"]}],
 "forms":[{"label":"复数","value":"serendipities"}],
 "examples":[{"source":"It was pure **serendipity**.","target":"这纯属机缘巧合。"}],
 "synonyms":["chance","fluke"],"translation":""}
"""

@Suite("Ask word cards")
struct AskWordCardTests {
    @Test(arguments: ["serendipity", "run", "take off", "by and large", "  Hello  ", "苹果", "一帆风顺", "りんご", "사과",
                      "e-mail", "don't"])
    func wordsAndShortPhrasesGetACard(text: String) {
        #expect(AskWordCard.isLookup(text))
    }

    @Test(arguments: ["", "   ", "The meeting moved to Thursday", "Hello, world", "Done.", "Really?", "这个功能下周上线",
                      "苹果，香蕉", "苹果 香蕉", "one\ntwo", "42", String(repeating: "a", count: 65)])
    func sentencesAndOddInputStayTranslations(text: String) {
        #expect(!AskWordCard.isLookup(text))
    }

    @Test func readsTheStructuredReply() {
        #expect(AskWordCard.parse(serendipityJSON) == .card(serendipity))
        // Wrapped in a code block or prose, as some models do.
        #expect(AskWordCard.parse("Here you go:\n```json\n\(serendipityJSON)\n```") == .card(serendipity))
    }

    @Test func aSentenceComesBackAsItsTranslation() {
        #expect(AskWordCard.parse(#"{"kind":"text","translation":" 会议改到周四了。 "}"#) == .translation("会议改到周四了。"))
        #expect(AskWordCard.parse(#"{"kind":"text","translation":""}"#) == .unreadable(#"{"kind":"text","translation":""}"#))
    }

    @Test func repliesThatAreNotCardsAreShownAsTheyCame() {
        #expect(AskWordCard.parse("  机缘巧合  ") == .unreadable("机缘巧合"))
        #expect(AskWordCard.parse("{not json}") == .unreadable("{not json}"))
        // A card without meanings says nothing.
        let empty = #"{"kind":"word","headword":"x","senses":[]}"#
        #expect(AskWordCard.parse(empty) == .unreadable(empty))
        // Missing optional parts are fine.
        let bare = #"{"headword":"run","senses":[{"pos":"v.","meanings":["跑"]}]}"#
        #expect(AskWordCard.parse(bare) == .card(AskWordCard(headword: "run", senses: [.init(pos: "v.", meanings: ["跑"])])))
    }

    @Test func aChattyReplyIsTrimmedToSize() {
        let card = AskWordCard(
            headword: "  run ",
            phonetics: [.init(label: "UK", text: "/rʌn/"), .init(label: "US", text: "/rʌn/"), .init(label: "x", text: "y"),
                        .init(label: "empty", text: " ")],
            senses: (1...5).map { AskWordCard.Sense(pos: "p\($0)", meanings: ["a", " ", "b", "c", "d", "e"]) }
                + [.init(pos: "none", meanings: [" "])],
            forms: (1...6).map { AskWordCard.Form(label: "f", value: "\($0)") },
            examples: [.init(source: "one", target: "1"), .init(source: " ", target: "2"), .init(source: "three", target: "3"),
                       .init(source: "four", target: "4")],
            synonyms: ["a", "", "b", "c", "d", "e", "f"]
        ).tidied()
        #expect(card.headword == "run")
        #expect(card.phonetics.count == 2)
        #expect(card.senses.count == 3)
        #expect(card.senses.allSatisfy { $0.meanings == ["a", "b", "c", "d"] })
        #expect(card.forms.count == 4)
        #expect(card.examples.map(\.source) == ["one", "three"])
        #expect(card.synonyms == ["a", "b", "c", "d", "e"])
    }

    @Test func copiesAsOneLineOrTheWholeCard() {
        #expect(serendipity.firstMeaning == "机缘巧合")
        #expect(serendipity.summary == "serendipity /ˌserənˈdɪpəti/ n. 机缘巧合；意外的好运")
        let markdown = serendipity.markdown
        #expect(markdown.hasPrefix("**serendipity** UK /ˌserənˈdɪpəti/ · US /ˌserənˈdɪpəti/"))
        #expect(markdown.contains("- *n.* 机缘巧合；意外的好运"))
        #expect(markdown.contains("复数: serendipities"))
        #expect(markdown.contains("> It was pure **serendipity**.\n> 这纯属机缘巧合。"))
        #expect(markdown.hasSuffix("chance, fluke"))
        let bare = AskWordCard(headword: "跑", senses: [.init(pos: "", meanings: ["run"])])
        #expect(bare.summary == "跑 run")
        #expect(bare.markdown == "**跑**\n- ** run")
        #expect(AskWordCard(headword: "x").firstMeaning == nil)
    }

    @Test func theSchemaAsksForEveryFieldStrictly() {
        let schema = AskWordCard.schema
        #expect(schema.name == "word_card" && schema.strict)
        guard case let .array(required) = schema.schema["required"],
              case let .object(properties) = schema.schema["properties"] else {
            Issue.record("schema is not an object"); return
        }
        let names = required.compactMap { if case let .string(name) = $0 { name } else { nil } }
        #expect(Set(names) == Set(properties.keys))
        #expect(Set(names) == ["kind", "headword", "phonetics", "senses", "forms", "examples", "synonyms", "translation"])
        guard case let .object(senses) = properties["senses"], case let .object(item) = senses["items"],
              case let .array(senseRequired) = item["required"] else {
            Issue.record("senses are not described"); return
        }
        #expect(senseRequired.count == 2)
        if case let .bool(extra) = item["additionalProperties"] { #expect(!extra) } else { Issue.record("open object") }
    }
}

@Suite("Ask word card view", .exclusiveUIState)
@MainActor
struct AskWordCardViewTests {
    @Test func phoneticsChooseAnAccent() {
        let speak = AskWordCardView.voice
        #expect(speak(.init(label: "UK", text: ""), "en") == "en-GB")
        #expect(speak(.init(label: "英", text: ""), "en") == "en-GB")
        #expect(speak(.init(label: "us", text: ""), "en") == "en-US")
        #expect(speak(.init(label: "美", text: ""), "en") == "en-US")
        #expect(speak(.init(label: "pinyin", text: ""), "zh-Hans") == "zh-Hans")
    }

    @Test func examplesMarkTheWordWithoutAsterisks() {
        let text = AskWordCardView.emphasized("It was pure **serendipity**, really.")
        #expect(String(text.characters) == "It was pure serendipity, really.")
        #expect(text.runs.count == 3)
        #expect(AskWordCardView.plain("a **b** c") == "a b c")
    }

    @Test func heightGrowsWithTheCardAndStopsAtTheLimit() {
        let bare = AskWordCard(headword: "run", senses: [.init(pos: "v.", meanings: ["跑"])])
        let small = AskWordCardView.contentHeight(bare)
        #expect(small >= AskWordCardView.headwordHeight + 20)
        let full = AskWordCardView.contentHeight(serendipity)
        #expect(full > small + 60, "forms, examples and synonyms add rows")
        var long = serendipity
        long.senses = (1...3).map { _ in AskWordCard.Sense(pos: "v.", meanings: Array(repeating: String(repeating: "很长的释义", count: 8), count: 4)) }
        long.examples = Array(repeating: .init(source: String(repeating: "word ", count: 40), target: "译文"), count: 2)
        #expect(AskWordCardView.contentHeight(long) > AskWordCardView.maximumHeight)
        #expect(AskWordCardView.height(long) == AskWordCardView.maximumHeight)
        #expect(AskWordCardView.height(bare) == small)
        #expect(AskWordCardView.formsText(serendipity) == "复数 serendipities")
        #expect(AskWordCardView.synonymsText(serendipity).hasSuffix("chance · fluke"))
    }

    @Test func theResultCardMakesRoomForAWordCard() {
        let output = AskPluginOutput(body: serendipity.summary, original: "serendipity", meta: [], source: "AI",
                                     actions: [AskPluginAction(kind: .speak("serendipity", language: "en"), title: "",
                                                               symbol: "", shortcut: nil)],
                                     wordCard: serendipity)
        let plain = AskPluginOutput(body: serendipity.summary, original: "serendipity", meta: [], source: "AI", actions: [])
        let withCard = AskPluginResultsView.cardHeight(output: output, failure: nil, comparing: true)
        let withText = AskPluginResultsView.cardHeight(output: plain, failure: nil, comparing: false)
        #expect(withCard - withText == AskWordCardView.height(serendipity) - AskPluginResultsView.bodyHeight(plain.body))
        #expect(AskPluginResultsView.spokenLanguage(output) == "en")
        #expect(AskPluginResultsView.spokenLanguage(plain) == nil)
        #expect(AskPluginResultsView.key(.shiftCommandC) == "⇧⌘C")
        var noted = output
        noted.note = "note"
        #expect(AskPluginResultsView.cardHeight(output: noted, failure: nil, comparing: false)
            == withCard + 6 + AskPluginResultsView.noteHeight)
    }

    @Test func rendersInTheLauncher() throws {
        let view = AskWordCardView(card: serendipity, language: "en", onAction: { _ in })
            .frame(width: AskPluginResultsView.textWidth)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: AskPluginResultsView.textWidth, height: AskWordCardView.height(serendipity))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }
}

@Suite("Ask word lookup")
struct AskWordLookupEngineTests {
    @Test func theAIWritesACardOnceAndReusesIt() async throws {
        let service = AskTestLLMService()
        service.jsonAnswer = serendipityJSON
        let engine = AskAITranslationEngine(service: service) { "m" }
        #expect(try await engine.lookUp(" Serendipity ", from: "en", to: "zh-Hans", generation: "0") == .card(serendipity))
        #expect(service.jsonPrompts.count == 1)
        #expect(service.jsonPrompts.first?.user == "Serendipity")
        #expect(service.jsonPrompts.first?.schema == "word_card")
        let prompt = service.jsonPrompts.first?.system ?? ""
        #expect(prompt.contains("in English") && prompt.contains("Chinese"))

        // The same word again is free; a new generation (⌘R) or target asks again.
        _ = try await engine.lookUp("serendipity", from: "en", to: "zh-Hans", generation: "0")
        #expect(service.jsonPrompts.count == 1)
        _ = try await engine.lookUp("serendipity", from: "en", to: "zh-Hans", generation: "1")
        _ = try await engine.lookUp("serendipity", from: "en", to: "ja", generation: "0")
        #expect(service.jsonPrompts.count == 3)
    }

    @Test func unreadableRepliesAreNotKept() async throws {
        let service = AskTestLLMService()
        service.jsonAnswer = "sorry"
        let engine = AskAITranslationEngine(service: service) { "m" }
        #expect(try await engine.lookUp("run", from: nil, to: "zh-Hans", generation: "0") == .unreadable("sorry"))
        service.jsonAnswer = serendipityJSON
        #expect(try await engine.lookUp("run", from: nil, to: "zh-Hans", generation: "0") == .card(serendipity))
        #expect(service.jsonPrompts.first?.system.contains("its own language") == true)

        service.jsonAnswer = "  "
        await #expect(throws: AskPluginFailure.self) {
            try await engine.lookUp("walk", from: "en", to: "zh-Hans", generation: "0")
        }
    }

    @Test func theCacheForgetsTheOldestCards() async throws {
        let service = AskTestLLMService()
        service.jsonAnswer = serendipityJSON
        let engine = AskAITranslationEngine(service: service) { "m" }
        for index in 0...AskAITranslationEngine.cachedCards {
            _ = try await engine.lookUp("word\(index)", from: "en", to: "zh-Hans", generation: "0")
        }
        let asked = service.jsonPrompts.count
        _ = try await engine.lookUp("word\(AskAITranslationEngine.cachedCards)", from: "en", to: "zh-Hans", generation: "0")
        #expect(service.jsonPrompts.count == asked, "recent cards stay")
        _ = try await engine.lookUp("word0", from: "en", to: "zh-Hans", generation: "0")
        #expect(service.jsonPrompts.count == asked + 1, "the oldest was dropped")
    }
}

@Suite("Ask translate plugin word cards")
struct AskTranslatePluginWordCardTests {
    private func request(_ text: String, origin: AskPluginRequest.Origin = .argument,
                         options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: origin, keyword: AskTranslatePlugin.keywords[0], options: options,
                         interfaceLanguage: .simplifiedChinese)
    }

    private func plugin(local: Bool, answer: AskWordLookup = .card(serendipity)) -> (AskTranslatePlugin, AskTestWordLookup) {
        let dictionary = AskTestWordLookup(answer: answer)
        return (AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: local), ai: AskTestTranslationEngine(),
                                   dictionary: dictionary, aiName: { "gpt-test" },
                                   detector: AskTestLanguageDetector(language: "en")), dictionary)
    }

    @Test func theAIAnswersAWordWithACard() async throws {
        let (translate, dictionary) = plugin(local: false)
        let plan = await translate.plan(request("serendipity"))
        #expect(plan.title == L("ask.plugin.translate.wordCard"))
        let output = try await translate.run(request("serendipity"), plan: plan)
        #expect(output.wordCard == serendipity)
        #expect(output.body == "机缘巧合" && output.sourceIsAI && output.note == nil)
        #expect(dictionary.requests.first?.generation == "0" && dictionary.requests.first?.target == "zh-Hans")
        #expect(output.action(for: .enter)?.kind == .copy("机缘巧合"))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("机缘巧合"))
        #expect(output.action(for: .optionEnter)?.title == L("ask.plugin.action.insert"))
        #expect(output.action(for: .shiftCommandC)?.kind == .copy(serendipity.markdown))
        #expect(output.action(for: .commandR)?.kind == .rerun(["engine": "ai", "generation": "1"]))
        #expect(output.actions.contains { $0.kind == .speak("serendipity", language: "en") })
        #expect(output.actions.contains { if case let .askAI(prompt) = $0.kind { prompt.contains("serendipity") } else { false } })

        let again = request("serendipity", options: ["engine": "ai", "generation": "1"])
        let regenerated = try await translate.run(again, plan: await translate.plan(again))
        #expect(dictionary.requests.last?.generation == "1")
        #expect(regenerated.action(for: .commandR)?.kind == .rerun(["engine": "ai", "generation": "2"]))

        let selected = request("serendipity", origin: .selection)
        let replaced = try await translate.run(selected, plan: await translate.plan(selected))
        #expect(replaced.action(for: .optionEnter)?.title == L("ask.plugin.action.replace"))
    }

    @Test func aWordInAnUnknownLanguageIsReadByItsScript() async throws {
        let dictionary = AskTestWordLookup(answer: .card(AskWordCard(headword: "苹果", senses: [.init(pos: "n.", meanings: ["apple"])])))
        let translate = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false), ai: AskTestTranslationEngine(),
                                           dictionary: dictionary, detector: AskTestLanguageDetector(language: nil))
        let output = try await translate.run(request("苹果"), plan: await translate.plan(request("苹果")))
        #expect(output.actions.contains { $0.kind == .speak("苹果", language: "zh-Hans") })
        dictionary.answer = .card(serendipity)
        let english = try await translate.run(request("serendipity"), plan: await translate.plan(request("serendipity")))
        #expect(english.actions.contains { $0.kind == .speak("serendipity", language: "en") })
        #expect(AskWordCard.containsCJK("한국어") && !AskWordCard.containsCJK("café"))
    }

    @Test func aCardWithoutMeaningsCannotWriteBack() async throws {
        let (translate, _) = plugin(local: false, answer: .card(AskWordCard(headword: "x")))
        let output = try await translate.run(request("x"), plan: await translate.plan(request("x")))
        #expect(output.action(for: .optionEnter) == nil)
    }

    @Test func sentencesAndUnreadableRepliesShowText() async throws {
        let (translate, _) = plugin(local: false, answer: .translation("会议改到周四。"))
        let output = try await translate.run(request("moved"), plan: await translate.plan(request("moved")))
        #expect(output.wordCard == nil && output.body == "会议改到周四。" && output.note == nil)
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("会议改到周四。"))
        #expect(output.action(for: .commandR)?.kind == .rerun(["engine": "ai", "generation": "1"]))

        let (odd, _) = plugin(local: false, answer: .unreadable("机缘巧合"))
        let shown = try await odd.run(request("moved"), plan: await odd.plan(request("moved")))
        #expect(shown.body == "机缘巧合" && shown.note == L("ask.plugin.translate.cardUnreadable"))
    }

    @Test func sentencesNeverAskTheDictionary() async throws {
        let (translate, dictionary) = plugin(local: false)
        let sentence = request("The meeting moved to Thursday.")
        let plan = await translate.plan(sentence)
        #expect(plan.title == L("ask.plugin.translate.title"))
        let output = try await translate.run(sentence, plan: plan)
        #expect(output.wordCard == nil && dictionary.requests.isEmpty)
    }

    @Test func onThisMacAWordOffersTheCard() async throws {
        let (translate, dictionary) = plugin(local: true)
        let plan = await translate.plan(request("serendipity"))
        #expect(plan.title == L("ask.plugin.translate.title"))
        let output = try await translate.run(request("serendipity"), plan: plan)
        #expect(output.wordCard == nil && dictionary.requests.isEmpty)
        #expect(output.note == L("ask.plugin.translate.cardHint", "gpt-test"))
        #expect(output.action(for: .commandR)?.title == L("ask.plugin.action.wordCard"))
        #expect(output.action(for: .commandR)?.kind == .rerun(["engine": "ai"]))

        // Without a dictionary nothing changes.
        let plain = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: AskTestTranslationEngine(),
                                       detector: AskTestLanguageDetector(language: "en"))
        let translated = try await plain.run(request("serendipity"), plan: await plain.plan(request("serendipity")))
        #expect(translated.note == nil && translated.action(for: .commandR)?.title == L("ask.plugin.action.retranslate"))
    }
}

@Suite("Ask command keys", .exclusiveUIState)
@MainActor
struct AskCommandKeyWordCardTests {
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) -> AskCommandKey? {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
            return nil
        }
        return AskCommandKey(event)
    }

    @Test func shiftCommandCCopiesTheWholeCard() {
        #expect(key("C", code: 8, modifiers: [.command, .shift]) == .shiftCommandC)
        #expect(key("c", code: 8, modifiers: .command) == .commandC)
        #expect(key("C", code: 8, modifiers: [.command, .shift, .option]) == nil)
    }
}

/// Providers that ignore the schema answer in their own shape (GUL-221 follow-up).
@Suite("Ask word card replies without a schema")
struct AskWordCardLooseReplyTests {
    @Test func readsTheShapeAModelInventedForHello() {
        let reply = """
        ```json
        {
          "kind": "word",
          "phonetics": [
            {"label": "UK", "value": "/həˈləʊ/"},
            {"label": "US", "value": "/həˈloʊ/"}
          ],
          "parts_of_speech": [
            {"part_of_speech": "interj.", "definitions": ["你好", "喂（打电话）"]},
            {"type": "n.", "definitions": [{"meaning": "招呼"}]}
          ],
          "example_sentences": [{"sentence": "**Hello**, how are you?", "translation": "你好，最近怎么样？"}],
          "synonyms": "hi"
        }
        ```
        """
        let expected = AskWordCard(
            headword: "hello",
            phonetics: [.init(label: "UK", text: "/həˈləʊ/"), .init(label: "US", text: "/həˈloʊ/")],
            senses: [.init(pos: "interj.", meanings: ["你好", "喂（打电话）"]), .init(pos: "n.", meanings: ["招呼"])],
            examples: [.init(source: "**Hello**, how are you?", target: "你好，最近怎么样？")],
            synonyms: ["hi"]
        )
        #expect(AskWordCard.parse(reply, word: "hello") == .card(expected))
    }

    @Test func readsOtherCommonShapes() {
        let byAccent = #"{"word":"run","pronunciation":{"US":"/rʌn/","UK":"/rʌn/"},"meanings":["跑","经营"],"#
            + #""inflections":{"past":"ran","plural":"runs"},"examples":["I run daily."]}"#
        #expect(AskWordCard.parse(byAccent) == .card(AskWordCard(
            headword: "run",
            phonetics: [.init(label: "UK", text: "/rʌn/"), .init(label: "US", text: "/rʌn/")],
            senses: [.init(pos: "", meanings: ["跑"]), .init(pos: "", meanings: ["经营"])],
            forms: [.init(label: "past", value: "ran"), .init(label: "plural", value: "runs")],
            examples: [.init(source: "I run daily.", target: "")]
        )))
        #expect(AskWordCard.parse(#"{"headword":"苹果","pinyin":"píngguǒ","senses":[{"pos":"n.","meaning":"apple"}]}"#)
            == .card(AskWordCard(headword: "苹果", phonetics: [.init(label: "pinyin", text: "píngguǒ")],
                                 senses: [.init(pos: "n.", meanings: ["apple"])])))
        #expect(AskWordCard.parse(#"{"phonetics":["/x/"],"senses":[{"pos":"n.","translations":["x"]}],"forms":[{"type":"pl.","form":"xs"}],"examples":[{"text":"An x."}]}"#, word: "x")
            == .card(AskWordCard(headword: "x", phonetics: [.init(label: "", text: "/x/")], senses: [.init(pos: "n.", meanings: ["x"])],
                                 forms: [.init(label: "pl.", value: "xs")], examples: [.init(source: "An x.", target: "")])))
    }

    @Test func aCardWithoutMeaningsFallsBackToItsTranslation() {
        #expect(AskWordCard.parse(#"{"kind":"word","headword":"hi","senses":[],"translation":"嗨"}"#) == .translation("嗨"))
        #expect(AskWordCard.parse(#"{"type":"text","translation":["会议改到周四。"]}"#) == .translation("会议改到周四。"))
        #expect(AskWordCard.parse("[1, 2]") == .unreadable("[1, 2]"))
    }

    @Test func structuredRepliesAreRecognised() {
        #expect(AskWordCard.looksStructured("```json\n{}\n```"))
        #expect(AskWordCard.looksStructured(#" {"kind": "#))
        #expect(AskWordCard.looksStructured("[1]"))
        #expect(AskWordCard.looksStructured(#"Here: {"a": 1}"#))
        #expect(!AskWordCard.looksStructured("机缘巧合"))
        #expect(!AskWordCard.looksStructured("hello {friend}"))
    }

    @Test func theAIIsToldTheExactShape() {
        let prompt = AskAITranslationEngine.wordCardPrompt(sourceName: "English", targetName: "Chinese")
        for key in ["\"headword\"", "\"phonetics\"", "\"text\"", "\"senses\"", "\"pos\"", "\"meanings\"", "\"examples\"",
                    "\"source\"", "\"target\"", "\"synonyms\"", "\"translation\""] {
            #expect(prompt.contains(key), "\(key) is spelled out")
        }
        #expect(prompt.contains("no Markdown code fences"))
    }
}

@Suite("Ask translate plugin garbled word cards")
struct AskTranslatePluginGarbledCardTests {
    private func request(_ text: String) -> AskPluginRequest {
        AskPluginRequest(text: text, origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: [:],
                         interfaceLanguage: .simplifiedChinese)
    }

    @Test func aGarbledCardBecomesAPlainTranslationNotRawJSON() async throws {
        let ai = AskTestTranslationEngine()
        let translate = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false), ai: ai,
                                           dictionary: AskTestWordLookup(answer: .unreadable("```json\n{\"kind\": \"word\"")),
                                           detector: AskTestLanguageDetector(language: "en"))
        let output = try await translate.run(request("hello"), plan: await translate.plan(request("hello")))
        #expect(output.body == "[zh-Hans] hello")
        #expect(!output.body.contains("{"))
        #expect(output.note == L("ask.plugin.translate.cardUnreadable"))
        #expect(ai.requests.map(\.text) == ["hello"])
        #expect(output.source == "AI", "no model name to show")
    }

    @Test func plainTextRepliesAreShownWithoutAskingAgain() async throws {
        let ai = AskTestTranslationEngine()
        let translate = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false), ai: ai,
                                           dictionary: AskTestWordLookup(answer: .unreadable("你好")),
                                           aiName: { "MiniMax M3" }, detector: AskTestLanguageDetector(language: "en"))
        let output = try await translate.run(request("hello"), plan: await translate.plan(request("hello")))
        #expect(output.body == "你好" && ai.requests.isEmpty)
        #expect(output.source == L("ask.plugin.source.ai", "MiniMax M3"))
    }

    @Test func resultCardsNameTheTextModel() throws {
        #expect(AskPluginRegistry.sourceLabel("AI") == "AI")
        #expect(AskPluginRegistry.sourceLabel("") == "AI")
        #expect(AskPluginRegistry.sourceLabel("gpt-x") == L("ask.plugin.source.ai", "gpt-x"))
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: "plugin-model-\(UUID())")))
        let configuration = settings.textLLMConfiguration()
        let name = AskPluginRegistry.modelName(settings)
        if configuration.provider == .typefluxCloud {
            #expect(name == LLMRemoteProvider.typefluxCloud.displayName)
        } else if !configuration.model.isEmpty {
            #expect(name == configuration.model)
        }
        #expect(AskPluginRegistry.modelName(nil) == "AI")
    }
}
