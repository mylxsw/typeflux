import AppKit
@testable import Typeflux
import XCTest

/// Keys the panel controller routes while editing before paste or confirming a delete, and the
/// panel-level shortcuts.
final class ClipboardPanelControllerKeyTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var controller: ClipboardPanelController!
    private var model: ClipboardPanelModel!
    private var commands: [ClipboardPanelCommand] = []

    override func setUp() {
        super.setUp()
        suite = "ClipboardPanelControllerKeyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        controller = ClipboardPanelController(settingsStore: SettingsStore(defaults: defaults))
        model = ClipboardPanelModel()
        commands = []
        model.onCommand = { [unowned self] in commands.append($0) }
        model.reset(entries: [
            ClipboardTestSupport.entry(.text, text: "first", sourceBundleID: "com.apple.Notes", sourceAppName: "Notes"),
            ClipboardTestSupport.entry(.text, text: "second")
        ])
    }

    override func tearDown() {
        controller.dismiss()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    @MainActor
    private func press(
        _ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false
    ) throws -> Bool {
        let panel = try XCTUnwrap(controller.presentedWindow)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode
        ))
        return controller.handleKeyDown(event)
    }

    @MainActor
    func testEditorKeepsTypingKeysAndHandlesEscapeAndCommandReturn() throws {
        controller.present(model)
        model.perform(.editBeforePaste, at: 1)
        XCTAssertEqual(model.editingText, "second")

        XCTAssertFalse(try press(125), "Arrows move the text cursor, not the selection")
        XCTAssertFalse(try press(123))
        XCTAssertFalse(try press(124))
        XCTAssertFalse(try press(0, "a"), "Typing goes to the editor")
        XCTAssertFalse(try press(36), "Return inserts a newline")
        XCTAssertEqual(model.selectedIndex, 1)

        XCTAssertTrue(try press(53))
        XCTAssertNil(model.editingText)

        model.perform(.editBeforePaste, at: 1)
        model.editingText = "second, edited"
        XCTAssertTrue(try press(36, flags: .command))
        XCTAssertEqual(commands, [.pasteText("second, edited")])
    }

    @MainActor
    func testConfirmationTakesReturnAndEscapeAndHoldsTheList() throws {
        controller.present(model)
        model.perform(.deleteAllFromApp, at: 0)
        XCTAssertNotNil(model.pendingConfirmation)

        XCTAssertTrue(try press(125), "Arrows are swallowed")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertFalse(try press(0, "a"))
        XCTAssertTrue(try press(53))
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(commands.isEmpty)

        model.requestClearUnpinned()
        XCTAssertTrue(try press(36))
        XCTAssertEqual(commands, [.clearUnpinned])
    }

    @MainActor
    func testPanelShortcutsIgnoreKeyRepeat() throws {
        controller.present(model)
        XCTAssertTrue(try press(35, "p", flags: [.command, .shift]))
        XCTAssertTrue(try press(35, "p", flags: [.command, .shift], repeat: true))
        XCTAssertTrue(try press(43, ",", flags: .command))
        XCTAssertEqual(commands, [.togglePause, .openSettings])

        XCTAssertTrue(try press(42, "\\", flags: .command, repeat: true))
        XCTAssertFalse(model.showsPreview, "A held ⌘\\ does not flicker the pane")
        XCTAssertTrue(try press(14, "e", flags: .command))
        XCTAssertEqual(model.editingText, "first")
    }

    @MainActor
    func testHorizontalArrowsSetPreviewVisibilityWithoutTogglingOrRepeating() throws {
        controller.reduceMotion = { true }
        controller.present(model)
        var changes: [Bool] = []
        model.onPreviewVisibilityChange = { changes.append($0) }
        XCTAssertTrue(try press(124, repeat: true))
        XCTAssertFalse(model.showsPreview)
        for isRepeat in [false, false, true] {
            XCTAssertTrue(try press(124, repeat: isRepeat))
            XCTAssertTrue(model.showsPreview)
        }
        XCTAssertEqual(controller.presentedWindow?.frame.width, ClipboardPanelView.size(showsPreview: true).width)
        for isRepeat in [false, false, true] {
            XCTAssertTrue(try press(123, repeat: isRepeat))
            XCTAssertFalse(model.showsPreview)
        }
        XCTAssertEqual(controller.presentedWindow?.frame.width, ClipboardPanelView.width)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(changes, [true, false])
    }

    @MainActor
    func testHorizontalArrowsKeepSearchCursorNavigationAndModifiedKeys() throws {
        controller.reduceMotion = { true }
        controller.present(model)
        model.query = "first"
        XCTAssertFalse(try press(124))
        XCTAssertFalse(model.showsPreview)
        model.showsPreview = true
        XCTAssertFalse(try press(123))
        XCTAssertTrue(model.showsPreview)
        model.query = ""
        XCTAssertFalse(try press(123, flags: .shift))
        XCTAssertFalse(try press(124, flags: .command))
        XCTAssertTrue(model.showsPreview)
    }

    @MainActor
    func testHorizontalArrowsDoNotInterruptMarkedTextComposition() throws {
        controller.present(model)
        let panel = try XCTUnwrap(controller.presentedWindow)
        let editor = NSTextView(frame: .zero)
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        editor.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(try press(123))
        XCTAssertFalse(try press(124))
        XCTAssertFalse(model.showsPreview)
    }
}
