import AppKit
import Testing
@testable import Typeflux

@Suite("Status bar word book", .serialized, .exclusiveUIState)
@MainActor
struct StatusBarWordBookMenuTests {
    @Test(arguments: AppLanguage.allCases)
    func `replaces add vocabulary with a localized word book`(language: AppLanguage) throws {
        let originalLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        let suite = "WordBookMenu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.appLanguage = language
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: settings,
            historyStore: FileHistoryStore(baseDir: directory)
        )
        controller.start()
        defer { controller.stop() }
        let menu = try #require(controller.menu)
        let title = L("ask.wordBook.title")
        #expect(title != "ask.wordBook.title")
        if language == .simplifiedChinese {
            #expect(title == "单词本")
        }
        #expect(menu.items.filter { $0.title == title }.count == 1)
        #expect(!menu.items.contains { $0.title == L("menu.addVocabulary") })
        #expect(!menu.items.contains { $0.action.map(NSStringFromSelector) == "addVocabularyTerm" })
        #expect(menu.items.prefix(3).map(\.title) == [L("menu.openVoiceStudio"), title, L("menu.notes")])
        #expect(menu.items[1].isEnabled && menu.items[1].submenu == nil)
        #expect(menu.items[1].target === controller)
    }

    @Test(arguments: [false, true])
    func `opens the translation word book and reuses its window`(hasWords: Bool) throws {
        let originalLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        let suite = "WordBookMenuWindow-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        let store = SQLiteAskWordBookStore(url: directory.appendingPathComponent("word-book.sqlite"))
        store.notificationCenter = NotificationCenter()
        let lookup = AskWordBookLookup(headword: "serendipity", source: "en", target: "zh-Hans", card: wordBookCard)
        if hasWords {
            store.record(lookup, at: Date(), counts: true)
            store.setStarred(true, lookup: lookup, at: Date())
        }
        let wordBook = AskWordBookWindowController()
        wordBook.configure(store: store, dictionary: nil, settings: settings, modelName: { "AI" })
        defer { wordBook.window?.close() }
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: settings,
            historyStore: FileHistoryStore(baseDir: directory),
            wordBookWindow: wordBook
        )
        controller.start()
        defer { controller.stop() }
        let menu = try #require(controller.menu)
        let index = try #require(menu.items.firstIndex { $0.title == L("ask.wordBook.title") })
        menu.performActionForItem(at: index)
        let window = try #require(wordBook.window)
        #expect(window.isVisible)
        #expect(window.title == L("ask.wordBook.title"))
        #expect(wordBook.model?.entries.count == (hasWords ? 1 : 0))
        if hasWords {
            #expect(wordBook.model?.entries.first?.key == lookup.key)
            #expect(wordBook.model?.entries.first?.isStarred == true)
        }
        menu.performActionForItem(at: index)
        #expect(wordBook.window === window)
        window.close()
        menu.performActionForItem(at: index)
        #expect(wordBook.window?.isVisible == true)
        #expect(wordBook.model?.entries.count == (hasWords ? 1 : 0))
    }
}
