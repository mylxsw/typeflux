import AppKit
import CoreAudio
import Testing
@testable import Typeflux

@Suite("Status bar word book", .serialized, .exclusiveUIState)
@MainActor
struct StatusBarWordBookMenuTests {
    @Test
    func `common features refreshes the screenshot shortcut when opened`() throws {
        let originalLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        let suite = "GroupedMenuShortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.screenshotHotkey = .defaultScreenshot
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: settings,
            historyStore: FileHistoryStore(baseDir: directory)
        )
        controller.start()
        defer { controller.stop() }
        let menu = try #require(controller.menu?.items.first { $0.title == L("menu.toolbox") }?.submenu)
        let screenshot = try #require(menu.items.first { $0.title == L("menu.screenshot") })
        #expect(!screenshot.keyEquivalent.isEmpty)
        settings.screenshotHotkey = nil
        controller.menuWillOpen(menu)
        #expect(screenshot.keyEquivalent.isEmpty)
        #expect(screenshot.keyEquivalentModifierMask.isEmpty)
        settings.screenshotHotkey = .defaultScreenshot
        controller.menuWillOpen(menu)
        #expect(screenshot.keyEquivalent == "a")
        #expect(screenshot.keyEquivalentModifierMask == [.command, .option])
    }

    @Test
    func `voice input keeps recent history refresh and persona selection working`() throws {
        let originalLanguage = AppLocalization.shared.language
        defer { AppLocalization.shared.setLanguage(originalLanguage) }
        let suite = "GroupedMenuVoice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = FileHistoryStore(baseDir: directory)
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: settings, historyStore: history
        )
        controller.start()
        defer { controller.stop() }
        let voiceMenu = try #require(controller.menu?.items.first { $0.title == L("menu.voiceInput") }?.submenu)
        let historyMenu = try #require(voiceMenu.items.first { $0.title == L("menu.transcriptionHistory") }?.submenu)
        #expect(historyMenu.items.first?.title == L("menu.transcriptionHistory.empty"))
        history.save(record: HistoryRecord(date: Date(), transcriptText: "Recent nested history"))
        controller.menuWillOpen(historyMenu)
        #expect(historyMenu.items.first?.representedObject as? String == "Recent nested history")
        #expect(historyMenu.items.last?.title == L("menu.transcriptionHistory.viewAll"))

        let personasMenu = try #require(voiceMenu.items.first { $0.title == L("menu.personas") }?.submenu)
        let persona = try #require(settings.personas.first)
        let index = try #require(personasMenu.items.firstIndex { $0.representedObject as? String == persona.id.uuidString })
        personasMenu.performActionForItem(at: index)
        #expect(settings.activePersonaID == persona.id.uuidString)
        #expect(settings.personaRewriteEnabled)
        controller.menuWillOpen(personasMenu)
        #expect(personasMenu.items.first { $0.representedObject as? String == persona.id.uuidString }?.state == .on)
        personasMenu.performActionForItem(at: 0)
        #expect(settings.activePersonaID.isEmpty)
        #expect(!settings.personaRewriteEnabled)
    }

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
        let rootMenu = try #require(controller.menu)
        let commonTitle = L("menu.toolbox")
        let voiceTitle = L("menu.voiceInput")
        #expect(commonTitle != "menu.toolbox")
        #expect(voiceTitle != "menu.voiceInput")
        #expect(rootMenu.items.prefix(4).map(\.title) == [
            L("menu.openVoiceStudio"), commonTitle, voiceTitle, L("menu.settings")
        ])
        let menu = try #require(rootMenu.items[1].submenu)
        let title = L("ask.wordBook.title")
        #expect(title != "ask.wordBook.title")
        if language == .simplifiedChinese {
            #expect(title == "单词本")
            #expect(commonTitle == "工具箱")
            #expect(L("menu.feedback") == "问题反馈")
        }
        #expect(menu.items.filter { $0.title == title }.count == 1)
        #expect(!menu.items.contains { $0.title == L("menu.addVocabulary") })
        #expect(!menu.items.contains { $0.action.map(NSStringFromSelector) == "addVocabularyTerm" })
        #expect(menu.items.filter { !$0.isHidden }.map(\.title) == [
            L("menu.screenshot"), L("menu.screenshotText"), L("recording.title"), L("menu.notes"), title
        ])
        let wordBookItem = try #require(menu.items.first { $0.title == title })
        #expect(wordBookItem.isEnabled && wordBookItem.submenu == nil)
        #expect(wordBookItem.target === controller)
        let voiceMenu = try #require(rootMenu.items[2].submenu)
        #expect(voiceMenu.items.prefix(3).map(\.title) == [
            L("settings.microphone.title"), L("menu.transcriptionHistory"), L("menu.personas")
        ])
        #expect(voiceMenu.items.contains { $0.title == L("menu.textTransformation") } == (language == .traditionalChinese))
    }

    @Test
    func `voice input microphone menu refreshes devices and saves the selected input`() throws {
        let suite = "VoiceMicrophoneMenu-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let devices = MenuAudioDeviceManager()
        devices.inputs = [AudioInputDevice(id: "built-in", name: "Mac Microphone")]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = StatusBarController(
            appState: AppStateStore(), settingsStore: settings,
            historyStore: FileHistoryStore(baseDir: directory), audioDeviceManager: devices
        )
        controller.start()
        defer { controller.stop() }

        let voiceMenu = try #require(controller.menu?.items.first { $0.title == L("menu.voiceInput") }?.submenu)
        let microphoneMenu = try #require(voiceMenu.items.first { $0.title == L("settings.microphone.title") }?.submenu)
        controller.menuWillOpen(microphoneMenu)
        #expect(microphoneMenu.items.map(\.title) == [L("settings.microphone.automatic"), "", "Mac Microphone"])
        #expect(microphoneMenu.items[0].state == .on)
        microphoneMenu.performActionForItem(at: 2)
        #expect(settings.preferredMicrophoneID == "built-in")

        devices.inputs.append(AudioInputDevice(id: "usb", name: "USB Microphone"))
        controller.menuWillOpen(microphoneMenu)
        #expect(microphoneMenu.items.map(\.title) == [
            L("settings.microphone.automatic"), "", "Mac Microphone", "USB Microphone"
        ])
        #expect(microphoneMenu.items[2].state == .on)
        microphoneMenu.performActionForItem(at: 3)
        #expect(settings.preferredMicrophoneID == "usb")

        devices.inputs.removeAll { $0.id == "usb" }
        microphoneMenu.performActionForItem(at: 3)
        #expect(settings.preferredMicrophoneID == "usb")
        controller.menuWillOpen(microphoneMenu)
        microphoneMenu.performActionForItem(at: 0)
        #expect(settings.preferredMicrophoneID == AudioDeviceManager.automaticDeviceID)
        controller.menuWillOpen(microphoneMenu)
        #expect(microphoneMenu.items[0].state == .on)
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
            try store.record(lookup, at: Date(), counts: true)
            try store.setStarred(true, lookup: lookup, at: Date())
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
        let rootMenu = try #require(controller.menu)
        let menu = try #require(rootMenu.items.first { $0.title == L("menu.toolbox") }?.submenu)
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

private final class MenuAudioDeviceManager: AudioDeviceManaging {
    var inputs: [AudioInputDevice] = []

    func availableInputDevices() -> [AudioInputDevice] { inputs }
    func resolveInputDeviceID(for _: String) -> AudioDeviceID? { nil }
    func defaultInputDeviceID() -> AudioDeviceID? { nil }
    func observeDefaultInputDeviceChanges(
        _: @escaping @Sendable () -> Void
    ) -> AudioInputDeviceChangeObservation? { nil }
}
