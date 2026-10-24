@testable import Typeflux
import XCTest

@MainActor
final class RingStudioControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: SettingsStore!
    private var model: RingSettingsModel!
    private var studio: RingStudioController!

    override func setUp() {
        super.setUp()
        suiteName = "RingStudioControllerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
        model = RingSettingsModel(settingsStore: store)
        studio = RingStudioController(model: model)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        studio = nil
        model = nil
        store = nil
        defaults = nil
        super.tearDown()
    }

    private var ids: [UUID] {
        model.actions.map(\.id)
    }

    private func setActions(_ actions: [RingAction]) {
        var configuration = store.ringConfiguration
        configuration.actions = actions
        store.ringConfiguration = configuration
    }

    // MARK: - Canvas

    func testStartsWithTheOverviewAndInsertionPoints() {
        XCTAssertEqual(studio.state, .overview)
        XCTAssertEqual(studio.canvasMode, .overview)
        XCTAssertEqual(studio.insertionIndexes, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(studio.slots.map(\.id), ids)
        XCTAssertNil(studio.selectedIndex)
    }

    func testModesFollowTheState() {
        studio.show(.edit(ids[1]))
        XCTAssertEqual(studio.canvasMode, .editing)
        XCTAssertEqual(studio.selectedIndex, 1)
        studio.show(.library(.replace(ids[2])))
        XCTAssertEqual(studio.canvasMode, .replacing)
        XCTAssertEqual(studio.insertionIndexes.count, 6)
        studio.show(.library(.insert(index: 2)))
        XCTAssertEqual(studio.canvasMode, .inserting)
        XCTAssertEqual(studio.insertionIndexes, [], "no ⊕ while a gap is open")
        XCTAssertEqual(studio.slots.count, 7)
        XCTAssertEqual(studio.selectedIndex, 2)
    }

    func testAnEmptyRingOpensTheLibrary() {
        setActions([])
        XCTAssertEqual(studio.state, .library(.insert(index: 0)))
        studio.cancelLibrary()
        XCTAssertEqual(studio.state, .library(.insert(index: 0)), "there is nothing else to show")
    }

    // MARK: - Library

    func testPickingInsertsAtTheGapAndEditsTheNewSlice() {
        studio.show(.library(.insert(index: 2)))
        studio.preview = RingActionLibrary.item(for: RingFeature.notes)
        XCTAssertEqual(studio.slots[2].role, .preview)
        studio.pick(RingActionLibrary.item(for: RingFeature.notes))
        XCTAssertEqual(model.actions[2].kind, .feature(.notes))
        XCTAssertEqual(studio.state, .edit(model.actions[2].id))
        XCTAssertNil(studio.preview, "the preview ends with the library")
    }

    func testPickingReplacesInPlace() {
        let target = ids[3]
        studio.show(.library(.replace(target)))
        studio.pick(RingActionLibrary.item(for: RingSystemAction.lockScreen))
        XCTAssertEqual(model.actions[3].id, target)
        XCTAssertEqual(model.actions[3].kind, .system(.lockScreen))
        XCTAssertEqual(studio.state, .edit(target))
    }

    func testPickingOutsideTheLibraryDoesNothing() {
        studio.pick(RingActionLibrary.item(for: RingFeature.notes))
        XCTAssertEqual(model.actions.count, 6)
        XCTAssertEqual(studio.state, .overview)
    }

    func testCancellingReturnsToWhereTheLibraryWasOpened() {
        studio.show(.library(.replace(ids[0])))
        studio.cancelLibrary()
        XCTAssertEqual(studio.state, .edit(ids[0]))
        studio.show(.library(.insert(index: 1)))
        studio.clickBackground()
        XCTAssertEqual(studio.state, .overview)
        studio.show(.edit(ids[0]))
        studio.clickBackground()
        XCTAssertEqual(studio.state, .overview)
    }

    func testAFullRingCannotOpenAGap() {
        setActions((0 ..< RingConfiguration.maxActions).map { _ in RingAction.feature(.notes) })
        studio.show(.library(.insert(index: 3)))
        XCTAssertEqual(studio.state, .overview)
        XCTAssertEqual(studio.insertionIndexes, [])
    }

    // MARK: - Editing

    func testRetargetingMovesADefaultNameAlong() {
        let url = RingAction(kind: .url("https://www.typeflux.app"), title: "typeflux.app", symbol: "link")
        let custom = RingAction(kind: .url("https://a.example"), title: "Docs", symbol: "link")
        setActions([url, custom])
        studio.retarget(url.id, to: .url("https://github.com"))
        XCTAssertEqual(model.actions[0].title, "github.com")
        XCTAssertEqual(model.actions[0].kind, .url("https://github.com"))
        studio.retarget(custom.id, to: .url("https://b.example"))
        XCTAssertEqual(model.actions[1].title, "Docs", "a chosen name stays")
        XCTAssertEqual(model.actions[1].kind, .url("https://b.example"))
    }

    func testMoveDuplicateDeleteResetAndUndo() {
        let first = ids[0]
        studio.move(first, to: 3)
        XCTAssertEqual(ids[3], first)
        XCTAssertEqual(studio.state, .edit(first))

        studio.duplicate(first)
        XCTAssertEqual(model.actions.count, 7)
        XCTAssertEqual(studio.state, .edit(ids[4]))
        XCTAssertNotEqual(ids[4], first)

        studio.delete(ids[4])
        XCTAssertEqual(model.actions.count, 6)
        XCTAssertEqual(studio.state, .overview)

        studio.undo()
        XCTAssertEqual(model.actions.count, 7)

        studio.show(.edit(ids[4]))
        let copy = ids[4]
        studio.undo()
        XCTAssertFalse(ids.contains(copy))
        XCTAssertEqual(studio.state, .overview, "an undone slice is no longer edited")

        studio.resetActions()
        XCTAssertEqual(model.actions, RingConfiguration.defaultActions())
        XCTAssertEqual(studio.state, .overview)
    }

    // MARK: - Trying

    func testTryingClosesTheLibraryAndOpeningTheLibraryStopsTrying() {
        studio.show(.library(.insert(index: 1)))
        studio.isTrying = true
        XCTAssertEqual(studio.state, .overview)
        studio.show(.library(.insert(index: 1)))
        XCTAssertFalse(studio.isTrying)
        studio.isTrying = true
        studio.handle(.escape)
        XCTAssertFalse(studio.isTrying, "Escape stops trying first")
    }

    // MARK: - Keys

    func testArrowKeysWalkTheRing() {
        studio.handle(.next)
        XCTAssertEqual(studio.state, .edit(ids[0]))
        studio.handle(.previous)
        XCTAssertEqual(studio.state, .edit(ids[5]), "wraps counter-clockwise")
        studio.handle(.next)
        XCTAssertEqual(studio.state, .edit(ids[0]))
        studio.show(.overview)
        studio.handle(.previous)
        XCTAssertEqual(studio.state, .edit(ids[5]))
        studio.handle(.select(2))
        XCTAssertEqual(studio.state, .edit(ids[2]))
        studio.handle(.select(9))
        XCTAssertEqual(studio.state, .edit(ids[2]), "a missing number is ignored")
        studio.handle(.edit)
        XCTAssertEqual(studio.state, .edit(ids[2]))
    }

    func testOptionArrowsMoveDeleteRemovesAndPlusInserts() {
        studio.handle(.select(0))
        let first = ids[0]
        studio.handle(.moveNext)
        XCTAssertEqual(ids[1], first)
        studio.handle(.movePrevious)
        XCTAssertEqual(ids[0], first)

        studio.handle(.insert)
        XCTAssertEqual(studio.state, .library(.insert(index: 1)), "inserts after the selection")
        studio.handle(.escape)
        XCTAssertEqual(studio.state, .overview)
        studio.handle(.insert)
        XCTAssertEqual(studio.state, .library(.insert(index: 6)), "without a selection it appends")
        studio.handle(.escape)

        studio.handle(.select(0))
        studio.handle(.delete)
        XCTAssertFalse(ids.contains(first))
        XCTAssertEqual(studio.state, .overview)
        let count = model.actions.count
        studio.handle(.delete)
        studio.handle(.moveNext)
        studio.handle(.edit)
        XCTAssertEqual(model.actions.count, count, "keys that need a selection do nothing without one")
    }

    func testKeysOnAnEmptyRing() {
        setActions([])
        studio.handle(.next)
        studio.handle(.previous)
        XCTAssertEqual(studio.state, .library(.insert(index: 0)))
    }
}
