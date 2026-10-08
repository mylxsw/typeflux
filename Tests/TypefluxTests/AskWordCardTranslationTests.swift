import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private let chineseWordJSON = """
{"kind":"word","headword":"狗蛋","translation":"silly fool",
 "phonetics":[{"label":"Pinyin","text":"gǒu dàn"}],
 "senses":[{"pos":"n.","meanings":["a rustic nickname for a boy; a silly or clueless fellow"]}],
 "forms":[],"examples":[{"source":"你这个**狗蛋**！","target":"You silly fool!"}],"synonyms":["狗子"]}
"""

@Suite("Ask word card target-language translation")
struct AskWordCardTranslationTests {
    @Test func wordsKeepTheirTranslationSeparateFromDefinitions() throws {
        guard case let .card(card) = AskWordCard.parse(chineseWordJSON) else {
            Issue.record("expected a word card"); return
        }
        #expect(card.headword == "狗蛋")
        #expect(card.translation == "silly fool")
        #expect(card.translatedText == "silly fool")
        #expect(card.firstMeaning == "a rustic nickname for a boy; a silly or clueless fellow")
        #expect(card.markdown.contains("\nsilly fool\n"))
        #expect(try JSONDecoder().decode(AskWordCard.self, from: JSONEncoder().encode(card)) == card)
    }

    @Test func oldSavedCardsAndBlankTranslationsUseTheFirstMeaning() throws {
        let old = AskWordCard(headword: "苹果", senses: [.init(pos: "n.", meanings: ["apple"])])
        let oldJSON = #"{"headword":"苹果","phonetics":[],"senses":[{"pos":"n.","meanings":["apple"]}],"#
            + #""forms":[],"examples":[],"synonyms":[]}"#
        let decoded = try JSONDecoder().decode(AskWordCard.self, from: Data(oldJSON.utf8))
        #expect(decoded == old && decoded.translatedText == "apple")
        var blank = old
        blank.translation = " \n "
        #expect(blank.translatedText == "apple")
        #expect(blank.tidied() == old)
        blank.translation = "  apple \n"
        #expect(blank.tidied().translation == "apple")
        #expect(AskWordCard(headword: "x").translatedText == nil)
    }

    @Test func aProviderCanOmitTheHeadwordWithoutLosingTheTranslation() {
        let reply = #"{"kind":"word","translated":" apple ","senses":[{"meaning":"a round fruit"}]}"#
        #expect(AskWordCard.parse(reply, word: "苹果") == .card(AskWordCard(
            headword: "苹果", translation: "apple", senses: [.init(pos: "", meanings: ["a round fruit"])]
        )))
    }

    @Test func theDictionaryAlwaysRequestsAConciseTargetLanguageEquivalent() async throws {
        let service = AskTestLLMService()
        service.jsonAnswer = chineseWordJSON
        let engine = AskAITranslationEngine(service: service) { "test-model" }
        guard case let .card(card) = try await engine.lookUp("狗蛋", from: "zh-Hans", to: "en", generation: "0") else {
            Issue.record("expected a word card"); return
        }
        #expect(card.translatedText == "silly fool")
        let prompt = try #require(service.jsonPrompts.first?.system)
        #expect(prompt.contains("natural English equivalent in \"translation\""))
        #expect(prompt.contains("including for words and short phrases"))
        #expect(!prompt.contains("Otherwise leave \"translation\" empty"))
        #expect(prompt.contains("Keep \"headword\" in the input language"))
        _ = try await engine.lookUp("狗蛋", from: "zh-Hans", to: "en", generation: "0")
        #expect(service.jsonPrompts.count == 1)
    }

    @Test(arguments: [AskPluginRequest.Origin.argument, .selection])
    func chineseWordsShowCopyAndInsertEnglishIncludingSavedCards(origin: AskPluginRequest.Origin) async throws {
        let store = makeTestWordBook()
        let service = AskTestLLMService()
        service.jsonAnswer = chineseWordJSON
        let engine = AskAITranslationEngine(service: service) { "test-model" }
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false), ai: engine,
                                        dictionary: engine, wordBook: store,
                                        detector: AskTestLanguageDetector(language: "zh-Hans"))
        let request = AskPluginRequest(text: "狗蛋", origin: origin, keyword: AskTranslatePlugin.keywords[0],
                                       options: [:], interfaceLanguage: .simplifiedChinese)
        let plan = await plugin.plan(request)
        #expect(plan.values["source"] == "zh-Hans" && plan.values["target"] == "en")
        let output = try await plugin.run(request, plan: plan)
        #expect(output.original == "狗蛋" && output.body == "silly fool")
        #expect(output.wordCard?.translatedText == "silly fool")
        #expect(output.action(for: .enter)?.kind == .copy("silly fool"))
        #expect(output.action(for: .optionEnter)?.kind == .writeBack("silly fool"))
        #expect(output.action(for: .optionEnter)?
            .title == L(origin == .selection ? "ask.plugin.action.replace" : "ask.plugin.action.insert"))
        // The original word's pinyin still uses its source language for pronunciation.
        #expect(output.actions.contains { $0.kind == .speak("狗蛋", language: "zh-Hans") })
        let lookup = try #require(output.wordBook)
        store.record(lookup, at: Date(), counts: true)
        let saved = try #require(store.entry(forKey: lookup.key))
        #expect(saved.lookup.card?.translation == "silly fool")
        #expect(saved.lookup.firstMeaning == "silly fool")
        #expect(AskTranslatePlugin.item(saved).actions.contains { $0.kind == .writeBack("silly fool") })
        let keptPlan = await plugin.plan(request)
        #expect(keptPlan.values["engine"] == "book")
        let kept = try await plugin.run(request, plan: keptPlan)
        #expect(kept.body == "silly fool" && !kept.sourceIsAI)
        #expect(kept.action(for: .enter)?.kind == .copy("silly fool"))
        #expect(service.jsonPrompts.count == 1)
    }

    @Test func englishWordsAndOtherTargetLanguagesUseTheirEquivalent() async throws {
        for (word, source, target, translation) in [("apple", "en", "zh-Hans", "苹果"), ("苹果", "zh-Hans", "ja", "りんご")] {
            let card = AskWordCard(headword: word, translation: translation,
                                   senses: [.init(pos: "n.", meanings: ["definition"])])
            let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(available: false),
                                            dictionary: AskTestWordLookup(answer: .card(card)),
                                            detector: AskTestLanguageDetector(language: source))
            let request = AskPluginRequest(text: word, origin: .argument, keyword: AskTranslatePlugin.keywords[0],
                                           options: ["target": target], interfaceLanguage: .simplifiedChinese)
            let output = try await plugin.run(request, plan: plugin.plan(request))
            #expect(output.body == translation)
            #expect(output.action(for: .enter)?.kind == .copy(translation))
            #expect(output.action(for: .optionEnter)?.kind == .writeBack(translation))
        }
    }
}

@Suite("Ask translated word card rendering", .serialized)
@MainActor
struct AskWordCardTranslationViewTests {
    @Test func longTranslationsGetEnoughRoomAndCardsStillScroll() {
        let short = AskWordCard(headword: "狗蛋", translation: "silly fool",
                                senses: [.init(pos: "n.", meanings: ["a silly fellow"])])
        var long = short
        long.translation = String(repeating: "a long translated phrase ", count: 40)
        #expect(AskWordCardView.contentHeight(long) > AskWordCardView.contentHeight(short))
        #expect(AskWordCardView.height(long) == AskWordCardView.maximumHeight)
    }

    @Test func rendersTheEnglishTranslationAboveTheChineseSource() async throws {
        guard case let .card(card) = AskWordCard.parse(chineseWordJSON) else {
            Issue.record("expected a word card"); return
        }
        _ = NSApplication.shared
        let size = NSSize(width: AskPluginResultsView.textWidth + 32, height: AskWordCardView.height(card) + 32)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let view = AskWordCardView(card: card, language: "zh-Hans", onAction: { _ in })
            .padding(16).background(StudioTheme.surface)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == size.height)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 4000)
        if let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try png.write(to: root.appendingPathComponent("word-card-zh-to-en.png"))
        }
    }
}
