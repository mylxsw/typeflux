import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Ask translate plugin: recent words")
struct AskTranslateRecentWordsTests {
    private func plugin(_ store: SQLiteAskWordBookStore?) -> AskTranslatePlugin {
        AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: nil, wordBook: store, aiName: { "gpt-test" },
                           detector: AskTestLanguageDetector(language: "en"))
    }

    private func empty(_ options: [String: String] = [:]) -> AskPluginRequest {
        AskPluginRequest(text: "", origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: options,
                         interfaceLanguage: .simplifiedChinese)
    }

    private func filled(_ store: SQLiteAskWordBookStore) {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0 ..< 10 {
            let lookup = AskWordBookLookup(headword: "w\(index)", source: "en", target: "zh-Hans",
                                           translation: index == 3 ? "" : "义\(index)")
            store.record(lookup, at: base.addingTimeInterval(Double(index)), counts: true)
            if index.isMultiple(of: 4) { store.setStarred(true, lookup: lookup, at: base.addingTimeInterval(Double(index))) }
        }
    }

    @Test func runsAloneOnlyWithAWordBook() {
        #expect(plugin(makeTestWordBook()).runsWithoutInput)
        #expect(!plugin(nil).runsWithoutInput)
    }

    @Test func listsTheLatestWordsThenTheWayIntoTheWordBook() async throws {
        let store = makeTestWordBook()
        filled(store)
        let translate = plugin(store)
        let plan = await translate.plan(empty())
        #expect(plan.mode == .live && plan.title == L("ask.wordBook.list.recent"))
        let output = try await translate.run(empty(), plan: plan)
        #expect(output.items.map(\.title) == ["w9", "w8", "w7", "w6", "w5", "w4", "w3", "w2", L("ask.wordBook.list.openAll")])
        #expect(output.note == nil && output.wordBook == nil && output.actions.isEmpty == false)
        let first = output.items[0]
        #expect(first.subtitle == "义9" && first.icon == .symbol("character.book.closed"))
        #expect(first.actions.first { $0.shortcut == .enter }?.kind == .runWith("w9"))
        #expect(first.actions.first { $0.shortcut == .optionEnter }?.kind == .writeBack("义9"))
        #expect(first.actions.first { $0.shortcut == .commandB }?.kind == .openWordBook(key: first.id))
        #expect(output.items[1].icon == .symbol("star.fill"))
        #expect(output.items[1].actions.first { $0.shortcut == .commandS }?.title == L("ask.wordBook.unstar"))
        #expect(!output.items[6].actions.contains { $0.shortcut == .optionEnter }, "no meaning to insert")
        let openAll = try #require(output.items.last)
        #expect(openAll.actions.first?.kind == .openWordBook(key: nil))
        #expect(openAll.actions.first?.title == L("ask.plugin.action.open"))
    }

    @Test func tabSwitchesToTheStarredWords() async throws {
        let store = makeTestWordBook()
        filled(store)
        let translate = plugin(store)
        let recent = await translate.plan(empty())
        let next = try #require(translate.nextOptions(after: recent, request: empty(), step: 1))
        #expect(next == [AskTranslatePlugin.listOption: "starred"])
        let starred = await translate.plan(empty(next))
        #expect(starred.title == L("ask.wordBook.list.starred"))
        let output = try await translate.run(empty(next), plan: starred)
        #expect(output.items.map(\.title).dropLast() == ["w8", "w4", "w0"])
        #expect(translate.nextOptions(after: starred, request: empty(next), step: 1) == [AskTranslatePlugin.listOption: "recent"])
    }

    @Test func anEmptyBookSaysHowToFillIt() async throws {
        let translate = plugin(makeTestWordBook())
        let output = try await translate.run(empty(), plan: await translate.plan(empty()))
        #expect(output.items.map(\.id) == [AskTranslatePlugin.openAllItem])
        #expect(output.note == L("ask.wordBook.list.empty"))
        let starred = empty([AskTranslatePlugin.listOption: "starred"])
        #expect(try await translate.run(starred, plan: await translate.plan(starred)).note
            == L("ask.wordBook.list.emptyStarred"))
    }

    @Test func aRowShowsItsStarWithoutRunningAgain() {
        let lookup = AskWordBookLookup(headword: "w", source: "en", target: "zh-Hans", translation: "义")
        let entry = AskWordBookEntry(id: UUID(), lookup: lookup, lookupCount: 1, firstLookedUpAt: Date(),
                                     lastLookedUpAt: Date(), starredAt: nil)
        let row = AskTranslatePlugin.item(entry)
        let starred = row.starring(true)
        #expect(starred.icon == .symbol("star.fill"))
        #expect(starred.actions.first { $0.shortcut == .commandS }?.title == L("ask.wordBook.unstar"))
        #expect(starred.starring(false) == row)
    }
}

extension AskQuickResultsInteractionTests {
    @Test func theKeywordAloneListsRecentWordsAndCommandBOpensTheWordBook() async throws {
        try await withPasteboard { _ in
            let translation = WordBookTranslation()
            let lookup = AskWordBookLookup(headword: "resilient", source: "en", target: "zh-Hans", translation: "有弹性的")
            translation.store.record(lookup, at: Date(), counts: true)
            var opened: [String?] = []
            let launcher = try await Launcher(text: "") { model in
                translation.install(in: model)
                model.openWordBook = { opened.append($0) }
            }
            defer { launcher.close() }
            let model = launcher.fixture.model
            for char in "fy " {
                launcher.editor.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(30))
            }
            for _ in 0 ..< 400 where model.plugins.output?.items.isEmpty != false { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.plugins.output?.items.first?.title == "resilient")

            try await launcher.press(Self.sKey, .command)
            #expect(translation.store.entry(forKey: lookup.key)?.isStarred == true)
            #expect(model.plugins.output?.items.first?.icon == .symbol("star.fill"), "the row shows the star in place")

            try await launcher.press(Self.bKey, .command)
            #expect(opened == [lookup.key])
            #expect(launcher.dismissed == 1)
        }
    }
}
