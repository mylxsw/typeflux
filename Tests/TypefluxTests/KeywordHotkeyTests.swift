import AppKit
@testable import Typeflux
import XCTest

final class KeywordHotkeyTests: XCTestCase {
    private let binding = HotkeyBinding(
        keyCode: 15,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )
    private let polish = AskKeyword(keyword: "rw", pluginID: AskPromptPlugin.id, options: ["preset": "polish"],
                                    aliases: ["polish"])
    private let fix = AskKeyword(keyword: "fix", pluginID: AskPromptPlugin.id)
    private let translate = AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id)

    func testResolvesByWordOrAliasWithinThePlugin() {
        let hotkey = KeywordHotkey(binding: binding, keyword: "polish", pluginID: AskPromptPlugin.id)
        XCTAssertEqual(hotkey.resolve(in: [fix, polish, translate]), polish)
        let other = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskPromptPlugin.id)
        XCTAssertNil(other.resolve(in: [fix, polish, translate]))
    }

    func testOnlyAWorkflowFallsBackToItsOnlyKeywordAfterARename() {
        let flow = AskKeyword(keyword: "new", pluginID: AskWorkflowPlugin.idPrefix + "local.demo")
        let hotkey = KeywordHotkey(binding: binding, keyword: "old", pluginID: flow.pluginID)
        XCTAssertEqual(hotkey.resolve(in: [translate, flow]), flow)
        let renamed = KeywordHotkey(binding: binding, keyword: "old", pluginID: AskTranslatePlugin.id)
        XCTAssertNil(renamed.resolve(in: [translate, polish]))
        let prompt = KeywordHotkey(binding: binding, keyword: "old", pluginID: AskPromptPlugin.id)
        XCTAssertNil(prompt.resolve(in: [fix, polish]))
    }

    func testStatus() {
        var hotkey = KeywordHotkey(binding: binding, keyword: "rw", pluginID: AskPromptPlugin.id)
        XCTAssertEqual(KeywordHotkeyStatus(hotkey, keywords: [polish]), .active)
        XCTAssertTrue(hotkey.isActive(in: [polish]))
        var off = polish
        off.enabled = false
        XCTAssertEqual(KeywordHotkeyStatus(hotkey, keywords: [off]), .keywordDisabled)
        XCTAssertFalse(hotkey.isActive(in: [off]))
        XCTAssertEqual(KeywordHotkeyStatus(hotkey, keywords: [fix, translate]), .keywordMissing)
        XCTAssertFalse(hotkey.isActive(in: []))
        hotkey.enabled = false
        XCTAssertEqual(KeywordHotkeyStatus(hotkey, keywords: [polish]), .disabled)
        hotkey.binding = nil
        XCTAssertEqual(KeywordHotkeyStatus(hotkey, keywords: [polish]), .unset)
    }

    func testDecodingDefaultsToEnabledAndKeepsAMissingBinding() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000009","keyword":"fy","pluginID":"translate"}"#
        let decoded = try JSONDecoder().decode(KeywordHotkey.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertNil(decoded.binding)
        let hotkey = KeywordHotkey(binding: binding, keyword: "rw", pluginID: AskPromptPlugin.id, enabled: false)
        XCTAssertEqual(try JSONDecoder().decode(KeywordHotkey.self, from: JSONEncoder().encode(hotkey)), hotkey)
    }

    func testDraftNeedsAKeywordAndUsableKeys() {
        var draft = KeywordHotkeyDraft(adding: nil)
        XCTAssertTrue(draft.isNew)
        XCTAssertFalse(draft.hasKeyword)
        XCTAssertFalse(draft.canSave(with: HotkeyConflictChecker.Result()))
        let option = KeywordHotkeyOption(keyword: polish, name: "Polish")
        draft.select(option)
        XCTAssertEqual(draft.selectedOption(in: [option]), option)
        XCTAssertFalse(draft.canSave(with: nil))
        draft.record(binding)
        XCTAssertTrue(draft.canSave(with: HotkeyConflictChecker.Result()))

        let other = UUID()
        let taken = HotkeyConflictChecker.Result(problem: .taken(.keyword(other)))
        XCTAssertEqual(draft.keywordOwner(in: taken), other)
        XCTAssertFalse(draft.canSave(with: taken))
        draft.takesKeys = true
        XCTAssertTrue(draft.canSave(with: taken))
        let builtIn = HotkeyConflictChecker.Result(problem: .taken(.builtIn(.ask)))
        XCTAssertNil(draft.keywordOwner(in: builtIn))
        XCTAssertFalse(draft.canSave(with: builtIn))
        draft.record(binding)
        XCTAssertFalse(draft.takesKeys)

        let editing = KeywordHotkeyDraft(editing: draft.hotkey)
        XCTAssertFalse(editing.isNew)
        XCTAssertEqual(KeywordHotkeyDraft(adding: option).hotkey.keyword, "rw")
    }
}

@MainActor
final class HotkeySettingsStoreTests: XCTestCase {
    private var suiteName = ""
    private let binding = HotkeyBinding(
        keyCode: 15,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )

    private func makeStore() throws -> SettingsStore {
        suiteName = "HotkeySettingsStoreTests.\(UUID().uuidString)"
        return try SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testActionHotkeysPersistAndNotify() throws {
        let store = try makeStore()
        XCTAssertTrue(store.actionHotkeys.isEmpty)
        let notified = expectation(forNotification: .hotkeySettingsDidChange, object: store)
        store.setHotkey(binding, for: .openChat)
        wait(for: [notified], timeout: 1)
        XCTAssertEqual(store.actionHotkeys, [.openChat: binding])
        XCTAssertEqual(store.hotkeyAssignments[.action(.openChat)], binding)
        store.setHotkey(nil, for: .openChat)
        XCTAssertTrue(store.actionHotkeys.isEmpty)
        XCTAssertNil(store.defaults.data(forKey: "hotkey.actions.json"))
    }

    func testUnknownStoredActionsAreIgnored() throws {
        let store = try makeStore()
        let data = try JSONEncoder().encode(["gone": binding, "openNotes": binding])
        store.defaults.set(data, forKey: "hotkey.actions.json")
        XCTAssertEqual(store.actionHotkeys, [.openNotes: binding])
    }

    func testBuiltInsThroughOneDoor() throws {
        let store = try makeStore()
        for builtIn in BuiltInHotkey.allCases {
            XCTAssertEqual(store.hotkey(builtIn)?.signature, builtIn.defaultBinding.signature, builtIn.rawValue)
        }
        store.setHotkey(nil, for: .history)
        XCTAssertNil(store.historyHotkey)
        store.setHotkey(binding, for: .persona)
        XCTAssertEqual(store.personaHotkey, binding)
        for builtIn in BuiltInHotkey.allCases {
            store.setHotkey(builtIn.defaultBinding, for: builtIn)
            XCTAssertEqual(store.hotkey(builtIn)?.signature, builtIn.defaultBinding.signature)
            XCTAssertFalse(builtIn.title.isEmpty)
        }
    }

    func testKeywordHotkeysPersistAndOnlyAssignedOnesHoldKeys() throws {
        let store = try makeStore()
        let assigned = KeywordHotkey(binding: binding, keyword: "rw", pluginID: AskPromptPlugin.id, enabled: false)
        let empty = KeywordHotkey(binding: nil, keyword: "fy", pluginID: AskTranslatePlugin.id)
        store.keywordHotkeys = [assigned, empty]
        XCTAssertEqual(store.keywordHotkeys, [assigned, empty])
        XCTAssertEqual(store.hotkeyAssignments[.keyword(assigned.id)], binding)
        XCTAssertNil(store.hotkeyAssignments[.keyword(empty.id)])
        XCTAssertTrue(
            EventTapHotkeyService.shortcutBindings(in: store).isEmpty,
            "switched-off shortcuts stay unregistered"
        )
        store.keywordHotkeys[0].enabled = true
        store.setHotkey(binding, for: .openNotes)
        XCTAssertEqual(EventTapHotkeyService.shortcutBindings(in: store),
                       [.keyword(assigned.id): binding, .action(.openNotes): binding])
        store.keywordHotkeys = []
        XCTAssertNil(store.defaults.data(forKey: "hotkey.keywords.json"))
    }

    func testRenamingAKeywordMovesItsShortcuts() throws {
        let store = try makeStore()
        let original = AskKeyword(keyword: "rw", pluginID: AskPromptPlugin.id, aliases: ["polish"])
        let follows = KeywordHotkey(binding: binding, keyword: "rw", pluginID: AskPromptPlugin.id)
        let alias = KeywordHotkey(binding: nil, keyword: "polish", pluginID: AskPromptPlugin.id)
        let other = KeywordHotkey(binding: nil, keyword: "rw", pluginID: AskTranslatePlugin.id)
        store.keywordHotkeys = [follows, alias, other]

        var renamed = original
        renamed.keyword = "rr"
        store.renameKeywordHotkeys(from: original, to: renamed)
        XCTAssertEqual(store.keywordHotkeys.map(\.keyword), ["rr", "polish", "rw"])

        store.renameKeywordHotkeys(from: renamed, to: renamed)
        XCTAssertEqual(store.keywordHotkeys.map(\.keyword), ["rr", "polish", "rw"])
    }
}

@MainActor
final class HotkeySettingsModelTests: XCTestCase {
    private var suiteName = ""
    private let binding = HotkeyBinding(
        keyCode: 15,
        modifierFlags: UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    )

    private func makeModel() throws -> HotkeySettingsModel {
        suiteName = "HotkeySettingsModelTests.\(UUID().uuidString)"
        let store = try SettingsStore(defaults: XCTUnwrap(UserDefaults(suiteName: suiteName)))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hotkey-workflows-" + UUID().uuidString)
        return HotkeySettingsModel(settingsStore: store, workflows: AskWorkflowStore(settings: store, root: root))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRowsCoverEveryCoreFeatureInPageOrder() throws {
        let model = try makeModel()
        let targets = model.rows.map(\.target)
        XCTAssertEqual(Set(targets), Set(BuiltInHotkey.allCases.map(HotkeyTarget.builtIn)
                + AppHotkeyAction.allCases.map(HotkeyTarget.action)))
        XCTAssertEqual(Array(targets.prefix(3)), [.builtIn(.activation), .builtIn(.auxiliary), .builtIn(.persona)])
        let groups = model.rows.map(\.group)
        XCTAssertEqual(
            groups,
            groups.sorted { HotkeyGroup.allCases.firstIndex(of: $0)! < HotkeyGroup.allCases.firstIndex(of: $1)! }
        )
        XCTAssertEqual(model.row(for: .builtIn(.activation))?.group, .voice)
        XCTAssertEqual(model.row(for: .action(.openChat))?.group, .launcher)
        XCTAssertEqual(model.row(for: .action(.openWordBook))?.group, .content)
        XCTAssertTrue(model.row(for: .builtIn(.ask))?.isDefault == true)
        XCTAssertNil(model.row(for: .action(.openNotes))?.binding)
        for row in model.rows {
            XCTAssertFalse(row.title.isEmpty)
            XCTAssertFalse(row.subtitle.hasPrefix("hotkeys."), row.subtitle)
            XCTAssertFalse(row.icon.isEmpty)
        }
        XCTAssertTrue(HotkeyGroup.allCases.allSatisfy { !$0.title.hasPrefix("hotkeys.") })
    }

    func testFeatureShortcutsCheckConflicts() throws {
        let model = try makeModel()
        XCTAssertNil(model.setHotkey(binding, for: .openChat))
        model.reload()
        XCTAssertEqual(model.row(for: .action(.openChat))?.binding, binding)
        XCTAssertEqual(model.setHotkey(binding, for: .openNotes),
                       L("hotkeys.conflict.usedBy", AppHotkeyAction.openChat.title))
        XCTAssertEqual(model.setHotkey(.defaultHistory, for: .openNotes),
                       L("hotkeys.conflict.usedBy", BuiltInHotkey.history.title))
        XCTAssertEqual(model.setHotkey(.rightCommandActivation, for: .openNotes), L("hotkeys.conflict.gesture"))
        model.unsetHotkey(for: .openChat)
        XCTAssertNil(model.settingsStore.actionHotkeys[.openChat])
    }

    func testKeywordShortcutLifecycle() throws {
        let model = try makeModel()
        let first = KeywordHotkey(binding: binding, keyword: "fy", pluginID: AskTranslatePlugin.id)
        model.save(first)
        model.reload()
        let row = try XCTUnwrap(model.row(for: .keyword(first.id)))
        XCTAssertEqual(row.group, .keywords)
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.title, "fy")

        var second = try XCTUnwrap(model.duplicate(first.id))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(second.binding)
        second.binding = binding
        XCTAssertEqual(model.check(binding, for: .keyword(second.id)).problem, .taken(.keyword(first.id)))
        XCTAssertEqual(model.message(for: .taken(.keyword(first.id))),
                       L("hotkeys.conflict.usedBy", L("hotkeys.keyword.name", "fy")))
        model.save(second, takingFrom: first.id)
        XCTAssertNil(model.keywordHotkey(first.id)?.binding)
        XCTAssertEqual(model.keywordHotkey(second.id)?.binding, binding)

        XCTAssertNotNil(model.setBinding(binding, forKeywordHotkey: first.id))
        let other = HotkeyBinding(keyCode: 17, modifierFlags: binding.modifierFlags)
        XCTAssertNil(model.setBinding(other, forKeywordHotkey: first.id))
        XCTAssertEqual(model.keywordHotkey(first.id)?.binding, other)
        XCTAssertNil(model.setBinding(other, forKeywordHotkey: UUID()))

        model.setEnabled(false, forKeywordHotkey: first.id)
        XCTAssertEqual(model.keywordHotkey(first.id)?.enabled, false)
        model.unsetBinding(forKeywordHotkey: first.id)
        XCTAssertNil(model.keywordHotkey(first.id)?.binding)
        model.delete(first.id)
        model.delete(second.id)
        XCTAssertTrue(model.settingsStore.keywordHotkeys.isEmpty)
        XCTAssertNil(model.duplicate(first.id))
    }

    func testRowsShowWhyAKeywordShortcutIsPaused() throws {
        let model = try makeModel()
        let missing = KeywordHotkey(binding: binding, keyword: "nothing", pluginID: "workflow.gone")
        model.save(missing)
        model.reload()
        let row = try XCTUnwrap(model.row(for: .keyword(missing.id)))
        XCTAssertEqual(row.status, .keywordMissing)
        XCTAssertEqual(row.title, "nothing")
        XCTAssertNotNil(HotkeySettingsPresentation.statusMessage(.keywordMissing))
        XCTAssertNil(HotkeySettingsPresentation.statusMessage(.active))
        for status in [KeywordHotkeyStatus.disabled, .unset, .keywordDisabled] {
            XCTAssertNotNil(HotkeySettingsPresentation.statusMessage(status))
        }
    }

    func testOptionsAndTemplates() throws {
        let model = try makeModel()
        XCTAssertFalse(model.options.isEmpty)
        XCTAssertTrue(model.options.allSatisfy { !$0.keyword.keyword.isEmpty })
        let templates = HotkeySettingsPresentation.templates(in: model.options)
        XCTAssertEqual(
            templates.map(\.keyword.pluginID),
            [AskPromptPlugin.id, AskTranslatePlugin.id, AskWebSearchPlugin.id]
        )

        let workflow = AskWorkflowKeywordEntry(
            keyword: "wf",
            workflowID: "local.demo",
            workflowName: "Demo",
            enabled: false
        )
        let taken = AskWorkflowKeywordEntry(
            keyword: "fy",
            workflowID: "local.clash",
            workflowName: "Clash",
            enabled: true
        )
        let options = HotkeySettingsPresentation.options(
            keywords: [
                AskKeyword(keyword: "fy", pluginID: AskTranslatePlugin.id),
                AskKeyword(keyword: "", pluginID: "x")
            ],
            workflows: [workflow, taken]
        )
        XCTAssertEqual(options.map(\.keyword.keyword), ["fy", "wf"])
        XCTAssertEqual(options.last?.keyword.pluginID, AskWorkflowPlugin.idPrefix + "local.demo")
        XCTAssertEqual(options.last?.name, "Demo")
        XCTAssertEqual(options.last?.keyword.enabled, false)
    }

    func testConflictMessagesKeepTheOlderCardsWording() throws {
        let model = try makeModel()
        let store = model.settingsStore
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.auxiliary, takenBy: .builtIn(.ask), in: store),
                       L("settings.shortcuts.auxiliaryConflict"))
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.ask, takenBy: .builtIn(.auxiliary), in: store),
                       L("settings.shortcuts.auxiliaryConflict"))
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.screenshot, takenBy: .builtIn(.ask), in: store),
                       L("settings.shortcuts.screenshotConflict"))
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.ask, takenBy: .builtIn(.screenshot), in: store),
                       L("settings.shortcuts.usedByScreenshot"))
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.persona, takenBy: .builtIn(.history), in: store),
                       L("settings.shortcuts.personaConflict"))
        XCTAssertEqual(HotkeyConflictMessages.builtIn(.history, takenBy: .action(.openNotes), in: store),
                       L("hotkeys.conflict.usedBy", AppHotkeyAction.openNotes.title))
        XCTAssertEqual(HotkeyConflictMessages.describe(.needsModifier, in: store), L("hotkeys.conflict.needsModifier"))
        XCTAssertEqual(HotkeyConflictMessages.name(of: .keyword(UUID()), in: store), L("hotkeys.keyword.name", ""))
    }
}
