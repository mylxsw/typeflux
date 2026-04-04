import XCTest
@testable import Typeflux

final class HotkeyFormatTests: XCTestCase {

    // MARK: - Special triggers

    func testDisplayRightCommandTrigger() {
        let binding = HotkeyBinding(keyCode: 54, modifierFlags: 1_048_576)
        XCTAssertEqual(HotkeyFormat.display(binding), "Right Command")
    }

    func testDisplayFnTrigger() {
        let binding = HotkeyBinding.defaultActivation
        XCTAssertEqual(HotkeyFormat.display(binding), "Fn")
    }

    // MARK: - Modifier flags

    func testDisplayCommandModifier() {
        let binding = HotkeyBinding(
            keyCode: 0,
            modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
        )
        let display = HotkeyFormat.display(binding)
        XCTAssertTrue(display.contains("⌘"))
        XCTAssertTrue(display.contains("A"))
    }

    func testDisplayShiftModifier() {
        let binding = HotkeyBinding(
            keyCode: 0,
            modifierFlags: UInt(NSEvent.ModifierFlags.shift.rawValue)
        )
        let display = HotkeyFormat.display(binding)
        XCTAssertTrue(display.contains("⇧"))
    }

    func testDisplayControlModifier() {
        let binding = HotkeyBinding(
            keyCode: 0,
            modifierFlags: UInt(NSEvent.ModifierFlags.control.rawValue)
        )
        let display = HotkeyFormat.display(binding)
        XCTAssertTrue(display.contains("⌃"))
    }

    func testDisplayOptionModifier() {
        let binding = HotkeyBinding(
            keyCode: 0,
            modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue)
        )
        let display = HotkeyFormat.display(binding)
        XCTAssertTrue(display.contains("⌥"))
    }

    func testDisplayMultipleModifiers() {
        let flags = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue
        let binding = HotkeyBinding(keyCode: 0, modifierFlags: UInt(flags))
        let parts = HotkeyFormat.components(binding)
        XCTAssertTrue(parts.contains("⇧"))
        XCTAssertTrue(parts.contains("⌘"))
        XCTAssertTrue(parts.contains("A"))
    }

    // MARK: - Key code mapping

    func testLetterKeys() {
        let expected: [(Int, String)] = [
            (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"),
            (5, "G"), (6, "Z"), (7, "X"), (8, "C"), (9, "V"),
            (11, "B"), (12, "Q"), (13, "W"), (14, "E"), (15, "R"),
            (16, "Y"), (17, "T"), (31, "O"), (32, "U"), (34, "I"),
            (35, "P"), (37, "L"), (38, "J"), (40, "K"), (45, "N"),
            (46, "M"),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }

    func testNumberKeys() {
        let expected: [(Int, String)] = [
            (18, "1"), (19, "2"), (20, "3"), (21, "4"),
            (23, "5"), (22, "6"), (26, "7"), (28, "8"),
            (25, "9"), (29, "0"),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }

    func testSpecialKeys() {
        let expected: [(Int, String)] = [
            (36, "Return"), (48, "Tab"), (49, "Space"),
            (51, "Delete"), (53, "Escape"), (50, "`"),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }

    func testArrowKeys() {
        let expected: [(Int, String)] = [
            (123, "←"), (124, "→"), (125, "↓"), (126, "↑"),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }

    func testFunctionKeys() {
        let expected: [(Int, String)] = [
            (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"),
            (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"),
            (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }

    func testUnmappedKeyCodeFallback() {
        let binding = HotkeyBinding(keyCode: 200, modifierFlags: 0)
        let parts = HotkeyFormat.components(binding)
        XCTAssertEqual(parts.last, "Key200")
    }

    func testPunctuationKeys() {
        let expected: [(Int, String)] = [
            (24, "="), (27, "-"), (30, "]"), (33, "["),
            (39, "'"), (41, ";"), (42, "\\"), (43, ","),
            (44, "/"), (47, "."),
        ]
        for (code, name) in expected {
            let binding = HotkeyBinding(keyCode: code, modifierFlags: 0)
            let parts = HotkeyFormat.components(binding)
            XCTAssertEqual(parts.last, name, "keyCode \(code) should map to \(name)")
        }
    }
}
