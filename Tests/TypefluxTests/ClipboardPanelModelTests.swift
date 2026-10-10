import Combine
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

    func testQuickPasteNumbersFollowSearchAndCategoryChanges() {
        model.reset(entries: entries)
        model.query = "words"
        model.quickPaste(number: 2)
        XCTAssertEqual(performed.map(\.1), ["plain words"])
        XCTAssertEqual(model.selectedIndex, 1)
        model.category = .text
        model.quickPaste(number: 1)
        model.quickPaste(number: 2)
        XCTAssertEqual(performed.map(\.1), ["plain words", "plain words"])
        XCTAssertEqual(model.selectedIndex, 0)
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

    func testRowsAreBuiltOnceWithSectionHeaders() {
        let now = Date()
        model.now = { now }
        let pinned = ClipboardTestSupport.entry(.text, date: now.addingTimeInterval(-9 * 86400), text: "pinned", isPinned: true)
        let today = ClipboardTestSupport.entry(.text, date: now, text: "today")
        let today2 = ClipboardTestSupport.entry(.text, date: now.addingTimeInterval(-1), text: "today 2")
        let old = ClipboardTestSupport.entry(.text, date: now.addingTimeInterval(-9 * 86400), text: "old")
        model.reset(entries: [pinned, today, today2, old])
        XCTAssertEqual(model.rows.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(model.rows.map(\.header), [.pinned, .today, nil, .earlier])
        XCTAssertEqual(model.rows.map(\.id), [pinned.id, today.id, today2.id, old.id])

        model.query = "today 2"
        XCTAssertEqual(model.rows.map(\.entry.title), ["today 2"])
        XCTAssertEqual(model.rows.first?.header, .today)
        XCTAssertEqual(model.rows.first?.index, 0)
    }

    func testMissingChecksAreCachedForRenderingButFreshForActions() {
        var checks = 0
        model.fileExists = { [unowned self] path in
            checks += 1
            return !missingPaths.contains(path)
        }
        model.reset(entries: entries)
        let pdf = model.visibleEntries[3]
        let text = model.visibleEntries[4]
        XCTAssertFalse(model.isMarkedMissing(pdf))
        XCTAssertFalse(model.isMarkedMissing(pdf))
        XCTAssertFalse(model.isMarkedMissing(text))
        XCTAssertEqual(checks, 1, "Rendering asks the disk once per entry; text never")

        // The file disappears while the panel is open: rendering keeps the cached state, but
        // the action checks again, refuses and updates the cache.
        missingPaths = ["/tmp/report.pdf"]
        XCTAssertTrue(model.isEnabled(.paste, for: pdf))
        model.perform(.paste, at: 3)
        XCTAssertTrue(performed.isEmpty)
        XCTAssertTrue(model.isMarkedMissing(pdf))
        XCTAssertFalse(model.isEnabled(.paste, for: pdf))

        // A new session forgets the cache.
        missingPaths = []
        model.reset(entries: entries)
        XCTAssertFalse(model.isMarkedMissing(pdf))
    }

    func testReplacingWithTheSameEntriesChangesNothing() {
        model.reset(entries: entries)
        model.select(index: 2)
        var rowChanges = 0
        let cancellable = model.$rows.dropFirst().sink { _ in rowChanges += 1 }
        model.replaceEntries(model.entries)
        XCTAssertEqual(rowChanges, 0)
        XCTAssertEqual(model.selectedIndex, 2)
        cancellable.cancel()
    }

    func testPreviewFollowsTheSelectionAfterADelay() {
        model.previewDelay = 0.05
        model.reset(entries: entries)
        XCTAssertNil(model.previewEntry, "The pane is hidden")

        model.showsPreview = true
        XCTAssertEqual(model.previewEntry?.title, "spoken words", "Opening the pane shows the selection at once")

        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.previewEntry?.title, "spoken words", "Moving through rows does not load each preview")
        let settled = expectation(description: "preview settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(self.model.previewEntry?.id, self.model.visibleEntries[2].id)
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)

        model.query = "plain"
        XCTAssertEqual(model.previewEntry?.title, "plain words", "A new search shows its first row immediately")

        var toggles: [Bool] = []
        model.onPreviewVisibilityChange = { toggles.append($0) }
        model.togglePreview()
        XCTAssertNil(model.previewEntry)
        model.togglePreview()
        XCTAssertEqual(toggles, [false, true])
    }

    func testPreviewWithoutDelayIsImmediate() {
        model.previewDelay = 0
        model.reset(entries: entries)
        model.showsPreview = true
        model.select(index: 4)
        XCTAssertEqual(model.previewEntry?.title, "plain words")
    }

    func testNumberShortcutsCountFromTheFirstVisibleRow() {
        model.reset(entries: entries)
        XCTAssertEqual(model.shortcutNumber(at: 0), 1)
        XCTAssertEqual(model.shortcutNumber(at: 4), 5)

        model.updateFirstVisibleIndex(2)
        XCTAssertNil(model.shortcutNumber(at: 1), "Rows scrolled above the viewport have no number")
        XCTAssertEqual(model.shortcutNumber(at: 2), 1)
        XCTAssertEqual(model.shortcutNumber(at: 4), 3)

        model.quickPaste(number: 1)
        model.quickPaste(number: 3)
        model.quickPaste(number: 4)
        XCTAssertEqual(performed.map(\.1), [model.visibleEntries[2].title, "plain words"])

        model.updateFirstVisibleIndex(99)
        XCTAssertEqual(model.firstVisibleIndex, 4, "Clamped to the last row")
        model.updateFirstVisibleIndex(-3)
        XCTAssertEqual(model.firstVisibleIndex, 0)

        model.updateFirstVisibleIndex(3)
        model.query = "words"
        XCTAssertEqual(model.firstVisibleIndex, 0, "A new search starts at the top")
    }

    func testANewSearchScrollsBackToTheTop() {
        model.reset(entries: entries)
        let before = model.scrollToTopRequest
        model.moveSelection(by: 2)
        XCTAssertEqual(model.scrollToTopRequest, before)
        model.category = .text
        XCTAssertEqual(model.scrollToTopRequest, before + 1)
    }

    func testFirstFullyVisibleIndexIgnoresRowsCutOffAtTheTop() {
        let frames: [Int: ClosedRange<CGFloat>] = [3: -20 ... 36, 4: 38 ... 94, 5: 96 ... 152, 6: 154 ... 300]
        XCTAssertEqual(ClipboardPanelModel.firstFullyVisibleIndex(frames: frames, viewportHeight: 280), 4)
        XCTAssertEqual(ClipboardPanelModel.firstFullyVisibleIndex(frames: [0: 0 ... 56], viewportHeight: 280), 0)
        XCTAssertEqual(
            ClipboardPanelModel.firstFullyVisibleIndex(frames: [2: -400 ... 400], viewportHeight: 280), 2,
            "A row taller than the viewport still counts"
        )
        XCTAssertEqual(
            ClipboardPanelModel.firstFullyVisibleIndex(frames: [0: -120 ... -60, 1: -58 ... 0.5, 2: 2 ... 58], viewportHeight: 280), 2
        )
        XCTAssertNil(ClipboardPanelModel.firstFullyVisibleIndex(frames: [:], viewportHeight: 280))
        XCTAssertNil(ClipboardPanelModel.firstFullyVisibleIndex(frames: [0: 400 ... 450], viewportHeight: 280))
    }

    func testClickSelectsOrPastes() {
        model.reset(entries: entries)
        model.click(index: 4)
        XCTAssertEqual(model.selectedIndex, 4)
        XCTAssertTrue(performed.isEmpty)
        model.singleClickPastes = true
        model.click(index: 1)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(performed.map(\.0), [.paste])
        XCTAssertEqual(performed.map(\.1), ["https://example.com"])
    }

    func testResetCanStartBelowPinnedRows() {
        let pinned = ClipboardTestSupport.entry(.text, text: "pinned", isPinned: true)
        let fresh = ClipboardTestSupport.entry(.text, text: "fresh")
        model.previewDelay = 0
        model.showsPreview = true
        model.reset(entries: [pinned, fresh], selectFirstUnpinned: true)
        XCTAssertEqual(model.selectedEntry?.title, "fresh")
        XCTAssertEqual(model.previewEntry?.title, "fresh")
        model.reset(entries: [pinned, fresh])
        XCTAssertEqual(model.selectedIndex, 0)
        model.reset(entries: [pinned], selectFirstUnpinned: true)
        XCTAssertEqual(model.selectedIndex, 0, "Only pinned rows: the first one")
    }

    private var appEntries: [ClipboardEntry] {
        [
            ClipboardTestSupport.entry(.text, text: "safari one", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari"),
            ClipboardTestSupport.entry(.text, text: "notes one", sourceBundleID: "com.apple.Notes", sourceAppName: "Notes"),
            ClipboardTestSupport.entry(
                .text, text: "safari pinned", sourceBundleID: "com.apple.Safari", sourceAppName: "Safari", isPinned: true
            ),
            ClipboardTestSupport.entry(.voice, text: "spoken")
        ]
    }

    func testShowOnlyAppFiltersAndEscapeClearsIt() {
        var commands: [ClipboardPanelCommand] = []
        model.onCommand = { commands.append($0) }
        model.reset(entries: appEntries)
        model.perform(.showOnlyApp, at: 0)
        XCTAssertEqual(model.appFilter, ClipboardAppFilter(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertEqual(model.visibleEntries.map(\.title), ["safari one", "safari pinned"])
        XCTAssertTrue(performed.isEmpty, "Handled in the panel")

        model.query = "pinned"
        XCTAssertEqual(model.visibleEntries.map(\.title), ["safari pinned"])
        model.cancel()
        XCTAssertEqual(model.query, "")
        XCTAssertNotNil(model.appFilter, "Escape clears the search before the app filter")
        model.cancel()
        XCTAssertNil(model.appFilter)
        XCTAssertEqual(model.visibleEntries.count, 4)
        XCTAssertEqual(dismissCount, 0)
        model.cancel()
        XCTAssertEqual(dismissCount, 1)

        // Voice results have no source app: the actions are not offered.
        model.perform(.showOnlyApp, at: 3)
        XCTAssertNil(model.appFilter)
        model.setAppFilter(ClipboardAppFilter(bundleID: "com.apple.Notes", name: "Notes"))
        model.reset(entries: appEntries)
        XCTAssertNil(model.appFilter, "A new session shows every app")
        XCTAssertTrue(commands.isEmpty)
    }

    func testDeletingAnAppsItemsAsksFirst() {
        var commands: [ClipboardPanelCommand] = []
        model.onCommand = { commands.append($0) }
        model.reset(entries: appEntries)
        model.perform(.deleteAllFromApp, at: 0)
        let safari = ClipboardAppFilter(bundleID: "com.apple.Safari", name: "Safari")
        XCTAssertEqual(model.pendingConfirmation, .deleteApp(safari, count: 1), "Pinned items are kept")
        XCTAssertEqual(model.pendingConfirmation?.message, L("clipboard.confirm.deleteApp", 1, "Safari"))
        model.cancel()
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(commands.isEmpty)

        model.perform(.deleteAllFromApp, at: 0)
        model.confirmPending()
        XCTAssertEqual(commands, [.deleteApp(bundleID: "com.apple.Safari")])
        XCTAssertNil(model.pendingConfirmation)
        model.confirmPending()
        XCTAssertEqual(commands.count, 1)
    }

    func testClearingUnpinnedItemsAsksFirstAndSkipsVoice() {
        var commands: [ClipboardPanelCommand] = []
        model.onCommand = { commands.append($0) }
        model.reset(entries: appEntries)
        model.requestClearUnpinned()
        XCTAssertEqual(model.pendingConfirmation, .clearUnpinned(count: 2))
        XCTAssertEqual(model.pendingConfirmation?.message, L("clipboard.confirm.clearUnpinned", 2))
        model.cancelPending()
        XCTAssertNil(model.pendingConfirmation)
        model.requestClearUnpinned()
        model.confirmPending()
        XCTAssertEqual(commands, [.clearUnpinned])

        model.reset(entries: [ClipboardTestSupport.entry(.voice, text: "only voice")])
        model.requestClearUnpinned()
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.notice, L("clipboard.notice.nothingToClear"))
    }

    func testEditingBeforePaste() {
        var commands: [ClipboardPanelCommand] = []
        model.onCommand = { commands.append($0) }
        model.reset(entries: entries)
        model.perform(.editBeforePaste, at: 4)
        XCTAssertEqual(model.editingText, "plain words")
        model.editingText = "plain words, edited"
        model.cancel()
        XCTAssertNil(model.editingText, "Escape leaves the editor first")
        XCTAssertEqual(dismissCount, 0)

        model.perform(.editBeforePaste, at: 4)
        model.editingText = "plain words, edited"
        model.commitEdit()
        XCTAssertEqual(commands, [.pasteText("plain words, edited")])
        XCTAssertNil(model.editingText)
        XCTAssertTrue(performed.isEmpty, "The stored entry is not pasted")

        model.perform(.editBeforePaste, at: 4)
        model.editingText = "   "
        model.commitEdit()
        XCTAssertEqual(commands.count, 1, "Blank text is not pasted")
        model.commitEdit()
        model.perform(.editBeforePaste, at: 2)
        XCTAssertNil(model.editingText, "Images cannot be edited")
        model.send(.openSettings)
        XCTAssertEqual(commands.last, .openSettings)
    }

    func testAppFilterOnlyComesFromClipboardEntriesWithASource() {
        XCTAssertNil(ClipboardAppFilter(entry: ClipboardTestSupport.entry(.voice, text: "x", sourceBundleID: "a")))
        XCTAssertNil(ClipboardAppFilter(entry: ClipboardTestSupport.entry(.text, text: "x", sourceBundleID: "")))
        XCTAssertEqual(
            ClipboardAppFilter(entry: ClipboardTestSupport.entry(.text, text: "x", sourceBundleID: "com.a")),
            ClipboardAppFilter(bundleID: "com.a", name: "com.a"), "Falls back to the bundle ID for a name"
        )
        XCTAssertEqual(ClipboardPanelConfirmation.clearUnpinned(count: 3).command, .clearUnpinned)
    }

    func testSectionsUseTheInjectedClock() {
        let now = Date()
        model.now = { now }
        XCTAssertEqual(model.section(for: ClipboardTestSupport.entry(.text, date: now)), .today)
        XCTAssertEqual(model.section(for: ClipboardTestSupport.entry(.text, isPinned: true)), .pinned)
    }
}
