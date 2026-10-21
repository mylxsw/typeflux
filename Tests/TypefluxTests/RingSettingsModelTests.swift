@testable import Typeflux
import XCTest

@MainActor
final class RingSettingsModelTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "RingSettingsModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Model

    func testChangesAreSavedImmediately() {
        let model = RingSettingsModel(settingsStore: store)
        model.setEnabled(false)
        model.setStyle(.classic)
        model.setCenterTitle("A very long centre title")
        XCTAssertFalse(store.ringConfiguration.enabled)
        XCTAssertEqual(store.ringConfiguration.style, .classic)
        XCTAssertEqual(store.ringConfiguration.centerTitle, "A very lon")
    }

    func testSaveAddsReplacesAndRespectsTheLimit() {
        let model = RingSettingsModel(settingsStore: store)
        let added = RingAction.feature(.notes)
        model.save(added)
        XCTAssertEqual(model.actions.last, added)

        var renamed = added
        renamed.title = "Jot"
        model.save(renamed)
        XCTAssertEqual(model.actions.count, 7)
        XCTAssertEqual(store.ringConfiguration.actions.last?.title, "Jot")

        model.save(.feature(.wordBook))
        model.save(.feature(.persona))
        XCTAssertEqual(model.actions.count, RingConfiguration.maxActions)
        XCTAssertFalse(model.actions.contains { $0.kind == .feature(.persona) })
    }

    func testDeleteDuplicateMoveAndReset() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        model.duplicate(first.id)
        XCTAssertEqual(model.actions[1].kind, first.kind)
        XCTAssertNotEqual(model.actions[1].id, first.id)

        model.move(first.id, by: -1)
        XCTAssertEqual(model.actions.first?.id, first.id, "the first slice cannot move further up")
        model.move(first.id, by: 2)
        XCTAssertEqual(model.actions[2].id, first.id)
        model.move(first.id, to: 99)
        XCTAssertEqual(model.actions.last?.id, first.id)

        model.delete(first.id)
        XCTAssertFalse(model.actions.contains { $0.id == first.id })
        XCTAssertEqual(store.ringConfiguration.actions.count, 6)

        model.duplicate(UUID())
        model.move(UUID(), by: 1)
        XCTAssertEqual(model.actions.count, 6)

        model.resetActions()
        XCTAssertEqual(model.actions.map(\.kind), RingConfiguration.defaultActions().map(\.kind))
    }

    func testDuplicateStopsAtTheLimit() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        for _ in 0..<5 { model.duplicate(first.id) }
        XCTAssertEqual(model.actions.count, RingConfiguration.maxActions)
    }

    func testFollowsChangesMadeElsewhere() {
        let model = RingSettingsModel(settingsStore: store)
        var configuration = store.ringConfiguration
        configuration.actions = []
        store.ringConfiguration = configuration
        XCTAssertTrue(model.actions.isEmpty)
    }

    // MARK: - Draft

    func testNewDraftNeedsATargetAndSuggestsItsTitle() throws {
        var draft = RingActionDraft.new()
        XCTAssertTrue(draft.isNew)
        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.action)

        draft.choose(.app(bundleIdentifier: "com.apple.Safari", name: "Safari"), title: "Safari")
        XCTAssertNil(draft.kind, "a target of another type is ignored")

        draft.choose(.feature(.translate), title: RingFeature.translate.title, symbol: RingFeature.translate.symbol)
        let action = try XCTUnwrap(draft.action)
        XCTAssertEqual(action.kind, .feature(.translate))
        XCTAssertEqual(action.title, RingFeature.translate.title)
        XCTAssertEqual(action.symbol, "character.bubble")
        XCTAssertEqual(action.id, draft.id)
    }

    func testTypedNameIsKeptUntilCleared() {
        var draft = RingActionDraft.new()
        draft.choose(.feature(.notes), title: "Notes", symbol: "note.text")
        draft.title = "Jot"
        draft.choose(.feature(.chat), title: "Chat", symbol: "bubble.left.and.bubble.right")
        XCTAssertEqual(draft.title, "Jot")

        draft.title = ""
        draft.choose(.feature(.notes), title: "Notes", symbol: "note.text")
        XCTAssertEqual(draft.title, "Notes")

        draft.title = "   "
        XCTAssertFalse(draft.canSave, "a blank name cannot be saved")
    }

    func testChangingTypeClearsTheTargetAndSuggestion() {
        var draft = RingActionDraft.new()
        draft.choose(.feature(.notes), title: "Notes", symbol: "note.text")
        draft.setType(.system)
        XCTAssertEqual(draft.type, .system)
        XCTAssertNil(draft.kind)
        XCTAssertEqual(draft.title, "")
        XCTAssertEqual(draft.symbol, RingActionType.system.symbol)
        draft.setType(.system)
        XCTAssertEqual(draft.type, .system)
    }

    func testTextTargets() {
        var draft = RingActionDraft.new()
        draft.setType(.url)
        XCTAssertTrue(draft.usesTextTarget)
        draft.setText("notaurl")
        XCTAssertTrue(draft.hasInvalidURL)
        XCTAssertNil(draft.kind)
        draft.setText(" https://www.typeflux.app/docs ")
        XCTAssertFalse(draft.hasInvalidURL)
        XCTAssertEqual(draft.kind, .url("https://www.typeflux.app/docs"))
        XCTAssertEqual(draft.title, "typeflux.app")

        draft.setType(.shortcut)
        draft.setText("Pomodoro")
        XCTAssertEqual(draft.kind, .shortcut(name: "Pomodoro"))
        XCTAssertEqual(draft.title, "Pomodoro")

        draft.setType(.folder)
        XCTAssertNil(draft.kind)
        draft.setText("~/Downloads")
        XCTAssertEqual(draft.kind, .folder(path: "~/Downloads"))
        XCTAssertEqual(draft.title, "Downloads")
        XCTAssertFalse(draft.hasInvalidURL)
    }

    func testEditingDraftStartsFromTheAction() throws {
        let url = RingAction(kind: .url("https://typeflux.app"), title: "Home", symbol: "globe")
        var draft = RingActionDraft(editing: url)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.type, .url)
        XCTAssertEqual(draft.text, "https://typeflux.app")
        draft.setText("https://example.com")
        XCTAssertEqual(draft.title, "Home", "an existing name is kept")
        XCTAssertEqual(try XCTUnwrap(draft.action).id, url.id)

        let app = RingAction(kind: .app(bundleIdentifier: "com.apple.Notes", name: "Notes"), title: "N", symbol: "app")
        XCTAssertEqual(RingActionDraft(editing: app).kind, app.kind)
        let shortcut = RingAction(kind: .shortcut(name: "Brief"), title: "Brief", symbol: "timer")
        XCTAssertEqual(RingActionDraft(editing: shortcut).kind, shortcut.kind)
        let folder = RingAction(kind: .folder(path: "/tmp"), title: "Tmp", symbol: "folder")
        XCTAssertEqual(RingActionDraft(editing: folder).kind, folder.kind)
    }
}
