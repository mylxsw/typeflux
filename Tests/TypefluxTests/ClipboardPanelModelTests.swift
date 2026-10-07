@testable import Typeflux
import XCTest

final class ClipboardPanelModelTests: XCTestCase {
    private var model: ClipboardPanelModel!
    private var performed: [(ClipboardEntryAction, String)] = []
    private var dismissCount = 0
    private var missingPaths: Set<String> = []

    override func setUp() {
        super.setUp()
        performed = []
        dismissCount = 0
        missingPaths = []
        model = ClipboardPanelModel()
        model.onAction = { [unowned self] action, entry in performed.append((action, entry.title)) }
        model.onDismiss = { [unowned self] in dismissCount += 1 }
        model.fileExists = { [unowned self] path in !missingPaths.contains(path) }
    }

    private var entries: [ClipboardEntry] {
        [
            ClipboardTestSupport.entry(.voice, text: "spoken words"),
            ClipboardTestSupport.entry(.link, text: "https://example.com"),
            ClipboardTestSupport.entry(.image, imagePath: "/tmp/shot.png"),
            ClipboardTestSupport.entry(.pdf, filePaths: ["/tmp/report.pdf"]),
            ClipboardTestSupport.entry(.text, text: "plain words")
        ]
    }

    func testResetShowsEverythingAndSelectsTheFirstRow() {
        model.query = "x"
        model.category = .file
        model.reset(entries: entries)
        XCTAssertEqual(model.visibleEntries.count, 5)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.category, .all)
        XCTAssertEqual(model.selectedEntry?.title, "spoken words")
    }

    func testSearchAndCategoryFilterAndResetSelection() {
        model.reset(entries: entries)
        model.moveSelection(by: 2)
        model.query = "words"
        XCTAssertEqual(model.visibleEntries.map(\.title), ["spoken words", "plain words"])
        XCTAssertEqual(model.selectedIndex, 0)

        model.moveSelection(by: 1)
        model.category = .text
        XCTAssertEqual(model.visibleEntries.map(\.title), ["plain words"])
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testSelectionIsClamped() {
        model.reset(entries: entries)
        model.moveSelection(by: -3)
        XCTAssertEqual(model.selectedIndex, 0)
        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedIndex, 4)
        model.select(index: 2)
        XCTAssertEqual(model.selectedIndex, 2)
        model.select(index: 40)
        XCTAssertEqual(model.selectedIndex, 2)

        model.reset(entries: [])
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.selectedEntry)
    }

    func testCycleCategoryWrapsBothWays() {
        model.reset(entries: entries)
        model.cycleCategory(forward: false)
        XCTAssertEqual(model.category, .voice)
        model.cycleCategory(forward: true)
        XCTAssertEqual(model.category, .all)
        model.cycleCategory(forward: true)
        XCTAssertEqual(model.category, .text)
    }

    func testReplaceEntriesKeepsTheSelectedRow() {
        var current = entries
        model.reset(entries: current)
        model.select(index: 3)
        let selectedID = model.selectedEntry?.id
        current.remove(at: 0)
        model.replaceEntries(current)
        XCTAssertEqual(model.selectedEntry?.id, selectedID)
        XCTAssertEqual(model.selectedIndex, 2)

        // The selected row disappeared: keep the same position.
        current.remove(at: 2)
        model.replaceEntries(current)
        XCTAssertEqual(model.selectedIndex, 2)
        current = Array(current.prefix(1))
        model.replaceEntries(current)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testPerformForwardsAvailableActions() {
        model.reset(entries: entries)
        model.perform(.paste)
        model.perform(.retryTranscription)
        model.perform(.quickLook)
        model.perform(.copy, at: 3)
        XCTAssertEqual(performed.map(\.0), [.paste, .retryTranscription, .copy])
        XCTAssertEqual(performed.last?.1, "report.pdf")
        XCTAssertEqual(model.selectedIndex, 3)
    }

    func testMissingFilesBlockContentActionsWithANotice() {
        missingPaths = ["/tmp/report.pdf"]
        model.reset(entries: entries)
        let pdf = model.visibleEntries[3]
        XCTAssertTrue(model.isMissing(pdf))
        XCTAssertFalse(model.isEnabled(.paste, for: pdf))
        XCTAssertTrue(model.isEnabled(.delete, for: pdf))

        model.perform(.paste, at: 3)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(model.notice, L("clipboard.notice.missingFile"))

        model.perform(.delete, at: 3)
        XCTAssertEqual(performed.map(\.0), [.delete])

        missingPaths = ["/tmp/shot.png"]
        XCTAssertTrue(model.isMissing(model.visibleEntries[2]))
        XCTAssertFalse(model.isMissing(model.visibleEntries[0]))
    }

    func testNoticeClearsItself() {
        model.showNotice("hello")
        XCTAssertEqual(model.notice, "hello")
        let cleared = expectation(description: "notice cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            XCTAssertNil(self.model.notice)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 3)
    }

    func testQuickPasteUsesVisibleRows() {
        model.reset(entries: entries)
        model.quickPaste(number: 2)
        model.quickPaste(number: 9)
        model.quickPaste(number: 0)
        XCTAssertEqual(performed.map(\.1), ["https://example.com"])
        XCTAssertEqual(performed.map(\.0), [.paste])
    }

    func testCancelClearsSearchBeforeDismissing() {
        model.reset(entries: entries)
        model.query = "zzz"
        XCTAssertTrue(model.visibleEntries.isEmpty)
        model.cancel()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(dismissCount, 0)
        model.cancel()
        XCTAssertEqual(dismissCount, 1)
    }

    func testSectionsUseTheInjectedClock() {
        let now = Date()
        model.now = { now }
        XCTAssertEqual(model.section(for: ClipboardTestSupport.entry(.text, date: now)), .today)
        XCTAssertEqual(model.section(for: ClipboardTestSupport.entry(.text, isPinned: true)), .pinned)
    }
}
