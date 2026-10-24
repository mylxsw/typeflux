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
        model.setStyle(.classic)
        model.setCenterTitle("A very long centre title")
        XCTAssertEqual(store.ringConfiguration.style, .classic)
        XCTAssertEqual(store.ringConfiguration.centerTitle, "A very lon")
    }

    func testInsertPutsTheSliceWhereAskedAndRespectsTheLimit() {
        let model = RingSettingsModel(settingsStore: store)
        let notes = RingAction.feature(.notes)
        XCTAssertTrue(model.insert(notes, at: 2))
        XCTAssertEqual(model.actions[2], notes)
        XCTAssertEqual(store.ringConfiguration.actions[2], notes, "saved at once")
        XCTAssertFalse(model.insert(notes, at: 0), "an id already on the ring is not added twice")

        XCTAssertTrue(model.insert(.feature(.wordBook), at: -5))
        XCTAssertEqual(model.actions.first?.kind, .feature(.wordBook), "a negative index inserts first")
        XCTAssertFalse(model.insert(.feature(.persona), at: 99), "the ring is full at 8")
        XCTAssertEqual(model.actions.count, RingConfiguration.maxActions)
        XCTAssertFalse(model.actions.contains { $0.kind == .feature(.persona) })
    }

    func testInsertPastTheEndAppends() {
        let model = RingSettingsModel(settingsStore: store)
        let chat = RingAction.feature(.chat)
        model.insert(chat, at: 42)
        XCTAssertEqual(model.actions.last, chat)
    }

    func testEditChangesOneSliceWithoutUndo() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        model.edit(first.id) {
            $0.title = "Talk"
            $0.symbol = "star"
        }
        XCTAssertEqual(model.actions.first?.title, "Talk")
        XCTAssertEqual(store.ringConfiguration.actions.first?.symbol, "star")
        XCTAssertFalse(model.canUndo, "renaming and icons are not undo steps")
        model.edit(UUID()) { $0.title = "Nobody" }
        XCTAssertFalse(model.actions.contains { $0.title == "Nobody" })
    }

    func testReplaceKeepsThePlaceAndCustomNames() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        let darkMode = RingActionLibrary.item(for: RingSystemAction.darkMode)
        model.replace(first.id, with: darkMode)
        XCTAssertEqual(model.actions.first?.id, first.id)
        XCTAssertEqual(model.actions.first?.kind, .system(.darkMode))
        XCTAssertEqual(model.actions.first?.title, RingSystemAction.darkMode.title, "a default name follows")
        XCTAssertEqual(model.actions.first?.symbol, RingSystemAction.darkMode.symbol)

        model.edit(first.id) {
            $0.title = "Night"
            $0.symbol = "moon"
        }
        model.replace(first.id, with: RingActionLibrary.item(for: RingSystemAction.mute))
        XCTAssertEqual(model.actions.first?.title, "Night", "a chosen name is kept")
        XCTAssertEqual(model.actions.first?.symbol, "moon", "a chosen icon is kept")
        XCTAssertEqual(model.actions.first?.kind, .system(.mute))

        let app = RingLibraryItem(kind: .app(bundleIdentifier: "com.apple.Notes", name: "Notes"), title: "Notes",
                                  subtitle: "", symbol: "app", group: "")
        model.replace(first.id, with: app)
        XCTAssertEqual(model.actions.first?.symbol, "app", "apps always draw their own icon")

        model.undo()
        XCTAssertEqual(model.actions.first?.kind, .system(.mute))
        let steps = model.canUndo
        model.replace(first.id, with: RingActionLibrary.item(for: RingSystemAction.mute))
        XCTAssertEqual(model.canUndo, steps, "replacing with the same target records nothing")
        model.replace(UUID(), with: app)
        XCTAssertEqual(model.actions.count, 6)
    }

    func testDeleteDuplicateMoveAndReset() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        let copy = try XCTUnwrap(model.duplicate(first.id))
        XCTAssertEqual(model.actions[1].id, copy)
        XCTAssertEqual(model.actions[1].kind, first.kind)
        XCTAssertNotEqual(copy, first.id)

        model.move(first.id, by: -1)
        XCTAssertEqual(model.actions.last?.id, first.id, "moving counter-clockwise from the top wraps around")
        model.move(first.id, by: 1)
        XCTAssertEqual(model.actions.first?.id, first.id, "and back")
        model.move(first.id, by: 2)
        XCTAssertEqual(model.actions[2].id, first.id)
        model.move(first.id, to: 99)
        XCTAssertEqual(model.actions.last?.id, first.id)

        model.delete(first.id)
        XCTAssertFalse(model.actions.contains { $0.id == first.id })
        XCTAssertEqual(store.ringConfiguration.actions.count, 6)

        XCTAssertNil(model.duplicate(UUID()))
        model.move(UUID(), by: 1)
        model.move(UUID(), to: 1)
        model.delete(UUID())
        XCTAssertEqual(model.actions.count, 6)

        model.resetActions()
        XCTAssertEqual(model.actions, RingConfiguration.defaultActions())
    }

    func testDuplicateStopsAtTheLimit() throws {
        let model = RingSettingsModel(settingsStore: store)
        let first = try XCTUnwrap(model.actions.first)
        for _ in 0 ..< 5 {
            model.duplicate(first.id)
        }
        XCTAssertEqual(model.actions.count, RingConfiguration.maxActions)
    }

    func testMoveNeedsTwoSlices() throws {
        let model = RingSettingsModel(settingsStore: store)
        var configuration = store.ringConfiguration
        configuration.actions = [.feature(.notes)]
        store.ringConfiguration = configuration
        let only = try XCTUnwrap(model.actions.first)
        model.move(only.id, by: 1)
        XCTAssertEqual(model.actions, [only])
        XCTAssertFalse(model.canUndo)
    }

    // MARK: - Undo

    func testUndoRestoresEachRecordedChangeInOrder() throws {
        let model = RingSettingsModel(settingsStore: store)
        let original = model.actions
        XCTAssertFalse(model.canUndo)
        let first = try XCTUnwrap(original.first)

        model.delete(first.id)
        XCTAssertEqual(model.lastChange, L("ring.undo.deleted", first.title))
        let chat = RingAction.feature(.chat)
        model.insert(chat, at: 0)
        XCTAssertEqual(model.lastChange, L("ring.undo.added", chat.title))
        model.move(chat.id, to: 3)
        XCTAssertEqual(model.lastChange, L("ring.undo.moved", chat.title))

        model.undo()
        XCTAssertEqual(model.actions.first?.id, chat.id)
        XCTAssertNil(model.lastChange, "undoing hides the bar")
        model.undo()
        XCTAssertFalse(model.actions.contains { $0.id == chat.id })
        model.undo()
        XCTAssertEqual(model.actions, original)
        XCTAssertEqual(store.ringConfiguration.actions, original, "undo is saved too")
        XCTAssertFalse(model.canUndo)
        model.undo()
        XCTAssertEqual(model.actions, original, "nothing left to undo")
    }

    func testResetIsUndoableAndSkippedWhenAlreadyDefault() throws {
        let model = RingSettingsModel(settingsStore: store)
        model.resetActions()
        XCTAssertFalse(model.canUndo, "the defaults are already there")
        let first = try XCTUnwrap(model.actions.first)
        model.edit(first.id) { $0.title = "Mine" }
        model.resetActions()
        XCTAssertEqual(model.lastChange, L("ring.undo.reset"))
        model.dismissLastChange()
        XCTAssertNil(model.lastChange)
        XCTAssertTrue(model.canUndo, "dismissing the bar keeps the step")
        model.undo()
        XCTAssertEqual(model.actions.first?.title, "Mine")
    }

    func testUndoKeepsOnlyTheLatestSteps() {
        let model = RingSettingsModel(settingsStore: store)
        var configuration = store.ringConfiguration
        configuration.actions = [.feature(.notes), .feature(.chat)]
        store.ringConfiguration = configuration
        let id = model.actions[0].id
        for _ in 0 ..< (RingSettingsModel.undoLimit + 5) {
            model.move(id, by: 1)
        }
        var undone = 0
        while model.canUndo {
            model.undo()
            undone += 1
        }
        XCTAssertEqual(undone, RingSettingsModel.undoLimit)
    }

    func testFollowsChangesMadeElsewhere() {
        let model = RingSettingsModel(settingsStore: store)
        var configuration = store.ringConfiguration
        configuration.actions = []
        store.ringConfiguration = configuration
        XCTAssertTrue(model.actions.isEmpty)
    }
}
