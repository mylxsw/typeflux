import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Typeflux

@Suite("Keyword shortcuts", .exclusiveUIState)
@MainActor
struct KeywordHotkeyRunnerTests {
    private let binding = HotkeyBinding(
        keyCode: 15,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )

    @Test func `enters the keyword with the selection`() throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        model.launcherDraft.text = "left over"
        model.launcherDraft.selection = "hello world"
        let keyword = try #require(model.plugins.availableKeywords.first { $0.pluginID == AskTranslatePlugin.id })
        model.runKeywordShortcut(KeywordHotkey(binding: binding, keyword: keyword.keyword, pluginID: keyword.pluginID))
        #expect(model.plugins.keyword?.pluginID == AskTranslatePlugin.id)
        #expect(model.launcherDraft.text.isEmpty)
    }

    @Test func `a missing keyword says so in the launcher`() throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession() }
        model.enterKeywordShortcut(KeywordHotkey(binding: binding, keyword: "gone", pluginID: "workflow.gone"),
                                   refreshingWorkflows: false)
        #expect(model.plugins.keyword == nil)
        #expect(model.commandFeedback == L("hotkeys.keyword.unavailable", "gone"))
    }

    @Test func `shows the launcher first when it can`() throws {
        let fixture = try AskTestFixture()
        let model = fixture.model
        defer { model.resetSession(); model.onShowLauncher = nil }
        var shown = 0
        model.onShowLauncher = { then in shown += 1; then() }
        let keyword = try #require(model.plugins.availableKeywords.first { $0.pluginID == AskTranslatePlugin.id })
        model.runKeywordShortcut(KeywordHotkey(binding: binding, keyword: keyword.keyword, pluginID: keyword.pluginID))
        #expect(shown == 1)
        #expect(model.plugins.keyword?.pluginID == AskTranslatePlugin.id)
    }

    @Test func `view model checks built ins against feature and keyword shortcuts`() throws {
        let name = "KeywordHotkeyRunnerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        let viewModel = StudioViewModel(settingsStore: store, historyStore: SQLiteHistoryStore(
            baseDir: FileManager.default.temporaryDirectory.appendingPathComponent("hotkeys-\(UUID())")
        ), initialSection: .settings)
        store.setHotkey(binding, for: .openNotes)
        viewModel.setPersonaHotkey(binding)
        #expect(viewModel.toastMessage == L("hotkeys.conflict.usedBy", AppHotkeyAction.openNotes.title))
        #expect(store.personaHotkey == .defaultPersona)

        let keyword = KeywordHotkey(binding: HotkeyBinding(keyCode: 17, modifierFlags: binding.modifierFlags),
                                    keyword: "fy", pluginID: AskTranslatePlugin.id)
        store.keywordHotkeys = [keyword]
        try viewModel.setHistoryHotkey(#require(keyword.binding))
        #expect(viewModel.toastMessage == L("hotkeys.conflict.usedBy", L("hotkeys.keyword.name", "fy")))

        let free = HotkeyBinding(keyCode: 16, modifierFlags: binding.modifierFlags)
        viewModel.setHistoryHotkey(free)
        #expect(store.historyHotkey == free)
        #expect(viewModel.historyHotkey == free)
        #expect(viewModel.toastMessage == L("settings.shortcuts.historyUpdated"))
    }

    @Test func `system hotkey pool skips gestures and maps modifiers`() {
        #expect(SystemHotkeyPool.canRegister(binding))
        #expect(!SystemHotkeyPool.canRegister(.rightCommandActivation))
        #expect(!SystemHotkeyPool.canRegister(.defaultAuxiliary))
        #expect(!SystemHotkeyPool.canRegister(HotkeyBinding(
            keyCode: 15,
            modifierFlags: binding.modifierFlags,
            pressCount: 2
        )))
        let all = UInt(NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue)
        #expect(SystemHotkeyPool.carbonModifierFlags(from: all) == UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(SystemHotkeyPool.carbonModifierFlags(from: 0) == 0)

        let pool = SystemHotkeyPool(name: "Test")
        pool.register([.action(.openChat): .rightCommandActivation])
        #expect(pool.registeredTargets.isEmpty)
        pool.unregisterAll()
    }

    @Test func `shortcuts are an app settings tab`() {
        #expect(AppSettingsPane.allCases == [.general, .appearance, .permissions, .hotkeys, .advanced])
        #expect(AppSettingsPane.hotkeys.symbol == "keyboard")
        #expect(AppSettingsPane.hotkeys.title == L("studio.section.hotkeys"))
    }
}
