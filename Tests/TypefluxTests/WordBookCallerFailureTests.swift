import Foundation
import Testing
@testable import Typeflux

@Suite("Word book caller failure reporting", .exclusiveUIState)
@MainActor
struct WordBookCallerFailureTests {
    @Test func translationSurvivesUnavailableStorageButHistoryReportsTheError() async throws {
        let store = SQLiteAskWordBookStore(url: URL(fileURLWithPath: "/dev/null/words.sqlite"))
        let plugin = AskTranslatePlugin(onDevice: AskTestTranslationEngine(), ai: AskTestTranslationEngine(),
                                       wordBook: store, detector: AskTestLanguageDetector(language: "en"))
        let request = AskPluginRequest(text: "word", origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: [:],
                                       interfaceLanguage: .english)
        let result = try await plugin.run(request, plan: await plugin.plan(request))
        #expect(!result.body.isEmpty && result.note == L("ask.wordBook.storageUnavailable"))
        let recent = AskPluginRequest(text: "", origin: .argument, keyword: AskTranslatePlugin.keywords[0], options: [:],
                                      interfaceLanguage: .english)
        do {
            _ = try await plugin.run(recent, plan: await plugin.plan(recent))
            Issue.record("Unavailable history must not look empty")
        } catch let error as AskPluginFailure { #expect(error.message == L("ask.wordBook.storageUnavailable")) }
    }

    @Test func launcherDoesNotShowStarSuccessAfterPersistenceFailure() async throws {
        let fixture = try AskTestFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SQLiteAskWordBookStore(url: URL(fileURLWithPath: "/dev/null/words.sqlite"))
        fixture.model.wordBook = AskWordBookRecorder(store: store)
        fixture.model.connectWordBook(to: fixture.model.plugins)
        let lookup = AskWordBookLookup(headword: "word", source: "en", target: "zh-Hans", translation: "meaning")
        fixture.model.toggleWordBookStar(lookup)
        await fixture.model.wordBookTask?.value
        #expect(fixture.model.commandFeedback == L("ask.wordBook.saveFailed"))
        fixture.model.commandFeedback = nil
        fixture.model.plugins.recordWordBook?(lookup)
        await fixture.model.wordBookTask?.value
        #expect(fixture.model.commandFeedback == L("ask.wordBook.saveFailed"))
        fixture.model.resetSession()
    }

    @Test func panelKeepsItsTranslationAndStarStateWhenSavingFails() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let lookup = AskWordBookLookup(headword: "word", source: "en", target: "zh-Hans", translation: "meaning")
        let result = AskPluginOutput(body: "result", original: lookup.headword, meta: [], source: "AI",
                                     actions: [AskTranslatePlugin.starAction(lookup, starred: false)], wordBook: lookup,
                                     starred: false)
        model.importLauncher(result)
        let defaults = fixture.settings
        let unavailable = RecoveringAskWordBookStore(factory: { throw LocalStoreFailure.unavailable })
        let plugin = AskTranslatePlugin(onDevice: fixture.device, ai: fixture.ai, wordBook: unavailable)
        let panel = AskTranslationPanelModel(settings: defaults, plugin: plugin, configuration: model.configuration, copy: { _ in })
        panel.importLauncher(result)
        panel.saveWordBook(lookup, toggle: true)
        await panel.wordBookTask?.value
        #expect(panel.output?.body == "result" && panel.output?.starred == false)
        #expect(panel.notice == L("ask.wordBook.saveFailed"))
        panel.notice = nil
        panel.saveWordBook(lookup, toggle: false)
        await panel.wordBookTask?.value
        #expect(panel.output?.body == "result" && panel.notice == L("ask.wordBook.saveFailed"))
        panel.dismiss()
        await unavailable.shutdown()
    }

    @Test func panelKeepsConfirmedStarAcrossStreamingAndDropsItForANewGeneration() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model
        let lookup = AskWordBookLookup(headword: "word", source: "en", target: "zh-Hans", translation: "meaning")
        let result = AskPluginOutput(body: "result", original: lookup.headword, meta: [], source: "AI",
                                     actions: [AskTranslatePlugin.starAction(lookup, starred: false)],
                                     wordBook: lookup, starred: false)
        model.importLauncher(result)
        let id = UUID()
        let handoff = AskPluginHandoff(plugin: model.plugin, plan: .init(mode: .onSubmit, title: ""),
            request: .init(text: lookup.headword, origin: .argument, keyword: AskTranslatePlugin.keywords[0],
                           options: [:], interfaceLanguage: .english), output: result, running: true, cancel: {})
        model.adoptHandoff(handoff, id: id)
        model.saveWordBook(lookup, toggle: true)
        await model.wordBookTask?.value
        #expect(model.output?.starred == true)
        model.receiveHandoff(.progress(result), id: id)
        #expect(model.output?.starred == true)
        model.receiveHandoff(.done(result), id: id)
        await model.wordBookTask?.value
        #expect(model.output?.starred == true)
        #expect(try fixture.book.entry(forKey: lookup.key)?.isStarred == true)
        let next = UUID()
        model.adoptHandoff(handoff, id: next)
        model.receiveHandoff(.progress(result), id: next)
        #expect(model.output?.starred == false, "A later generation takes a fresh storage snapshot")
    }

}
