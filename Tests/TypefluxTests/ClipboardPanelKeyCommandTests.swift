import AppKit
@testable import Typeflux
import XCTest

final class ClipboardPanelKeyCommandTests: XCTestCase {
    private func command(
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        _ characters: String? = nil,
        queryIsEmpty: Bool = true,
        selection: Bool = false
    ) -> ClipboardPanelKeyCommand? {
        ClipboardPanelKeyCommand.command(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters,
            queryIsEmpty: queryIsEmpty,
            hasTextSelection: selection
        )
    }

    func testNavigationKeys() {
        XCTAssertEqual(command(126), .moveUp)
        XCTAssertEqual(command(125), .moveDown)
        XCTAssertNil(command(125, .shift))
        XCTAssertEqual(command(48), .nextCategory)
        XCTAssertEqual(command(48, .shift), .previousCategory)
        XCTAssertNil(command(48, .command))
        XCTAssertEqual(command(53), .cancel)
        XCTAssertEqual(command(53, .command), .cancel)
    }

    func testCommandBackslashTogglesThePreview() {
        XCTAssertEqual(command(42, .command, "\\"), .togglePreview)
        XCTAssertNil(command(42, [], "\\"))
        XCTAssertNil(command(42, [.command, .shift], "\\"))
    }

    func testHorizontalArrowsOpenAndCloseThePreview() {
        XCTAssertEqual(command(124), .showPreview)
        XCTAssertEqual(command(123), .hidePreview)
        XCTAssertEqual(command(124, [.numericPad, .function]), .showPreview)
        XCTAssertEqual(command(123, [.numericPad, .function]), .hidePreview)
    }

    func testHorizontalArrowsKeepSearchAndTextSelectionNavigation() {
        for key: UInt16 in [123, 124] {
            XCTAssertNil(command(key, queryIsEmpty: false))
            XCTAssertNil(command(key, selection: true))
            for modifier in [NSEvent.ModifierFlags.command, .shift, .option, .control] {
                XCTAssertNil(command(key, modifier))
            }
        }
    }

    func testPanelShortcuts() {
        XCTAssertEqual(command(14, .command, "e"), .action(.editBeforePaste))
        XCTAssertEqual(command(43, .command, ","), .openSettings)
        XCTAssertEqual(command(35, [.command, .shift], "P"), .togglePause)
        XCTAssertEqual(command(35, .command, "p"), .action(.togglePin))
        XCTAssertNil(command(35, [.command, .option], "p"))
    }

    func testReturnPastes() {
        XCTAssertEqual(command(36), .action(.paste))
        XCTAssertEqual(command(76), .action(.paste))
        XCTAssertEqual(command(36, .command), .action(.pastePlainText))
        XCTAssertNil(command(36, .option))
        // Caps Lock and function flags do not change the meaning.
        XCTAssertEqual(command(36, [.capsLock, .numericPad]), .action(.paste))
    }

    func testCommandShortcuts() {
        XCTAssertEqual(command(35, .command, "p"), .action(.togglePin))
        XCTAssertEqual(command(16, .command, "Y"), .action(.quickLook))
        XCTAssertEqual(command(8, .command, "c"), .action(.copy))
        XCTAssertNil(command(8, .command, "c", selection: true))
        XCTAssertEqual(command(18, .command, "1"), .quickPaste(1))
        XCTAssertEqual(command(25, .command, "9"), .quickPaste(9))
        XCTAssertNil(command(29, .command, "0"))
        XCTAssertNil(command(35, [], "p"))
        XCTAssertEqual(command(35, [.command, .shift], "p"), .togglePause)
        XCTAssertNil(command(0, .command, "a"))
        XCTAssertNil(command(0, .command, nil))
    }

    func testCommandBackspaceDeletesOnlyWithoutSearchText() {
        XCTAssertEqual(command(51, .command), .action(.delete))
        XCTAssertNil(command(51, .command, queryIsEmpty: false))
        XCTAssertNil(command(51))
    }

    func testNumberShortcutsMatchTheLauncherAndAllowSearching() {
        for (index, code) in [UInt16(18), 19, 20, 21, 23, 22, 26, 28, 25].enumerated() {
            XCTAssertEqual(command(code, .command, String(index + 1), queryIsEmpty: false, selection: true), .quickPaste(index + 1))
            XCTAssertEqual(command(code, .command, nil), .quickPaste(index + 1))
            XCTAssertNil(command(code, [], String(index + 1)))
            XCTAssertNil(command(code, [.command, .shift], String(index + 1)))
            XCTAssertNil(command(code, [.command, .option], String(index + 1)))
            XCTAssertNil(command(code, [.command, .control], String(index + 1)))
        }
        XCTAssertEqual(command(92, [.command, .numericPad], "9"), .quickPaste(9))
        XCTAssertNil(command(18, .command, "!"))
    }
}
