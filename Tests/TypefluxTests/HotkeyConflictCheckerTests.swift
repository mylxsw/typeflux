import AppKit
@testable import Typeflux
import XCTest

final class HotkeyConflictCheckerTests: XCTestCase {
    private let controlOption = UInt(NSEvent.ModifierFlags.control.union(.option).rawValue)
    private let keywordID = UUID()

    private func chord(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> HotkeyBinding {
        HotkeyBinding(keyCode: keyCode, modifierFlags: UInt(flags.rawValue))
    }

    func testPlainChordIsFree() {
        let result = HotkeyConflictChecker.check(chord(15, [.control, .option]), for: .action(.openChat), among: [:])
        XCTAssertNil(result.problem)
        XCTAssertTrue(result.canSave)
        XCTAssertFalse(result.overridesSystemShortcut)
    }

    func testGesturesAreReservedForVoiceInput() {
        for gesture in [HotkeyBinding.rightCommandActivation, .rightOptionAsk, .defaultActivation, .defaultAuxiliary,
                        HotkeyBinding(keyCode: 15, modifierFlags: controlOption, pressCount: 2)] {
            let result = HotkeyConflictChecker.check(gesture, for: .keyword(keywordID), among: [:])
            XCTAssertEqual(result.problem, .gesture, HotkeyFormat.display(gesture))
            XCTAssertFalse(result.canSave)
        }
    }

    func testShortcutsNeedCommandOptionOrControlUnlessAnFKey() {
        XCTAssertEqual(HotkeyConflictChecker.check(chord(15, .shift), for: .action(.openNotes), among: [:]).problem,
                       .needsModifier)
        XCTAssertEqual(HotkeyConflictChecker.check(chord(15, .function), for: .action(.openNotes), among: [:]).problem,
                       .needsModifier)
        XCTAssertNil(HotkeyConflictChecker.check(chord(96, .function), for: .action(.openNotes), among: [:]).problem)
        XCTAssertNil(HotkeyConflictChecker.check(chord(15, .command), for: .action(.openNotes), among: [:]).problem)
    }

    func testBuiltInShortcutsKeepAcceptingGestures() {
        let result = HotkeyConflictChecker.check(.rightCommandActivation, for: .builtIn(.activation), among: [:])
        XCTAssertNil(result.problem)
        XCTAssertNil(HotkeyConflictChecker.check(chord(15, .shift), for: .builtIn(.persona), among: [:]).problem)
    }

    func testTakenKeysNameTheirOwnerAndIgnoreTheTargetItself() {
        let binding = chord(15, [.control, .option])
        let assignments: [HotkeyTarget: HotkeyBinding] = [
            .builtIn(.ask): .defaultAsk, .action(.openNotes): binding, .keyword(keywordID): chord(17, .command)
        ]
        XCTAssertEqual(HotkeyConflictChecker.check(binding, for: .keyword(UUID()), among: assignments).problem,
                       .taken(.action(.openNotes)))
        XCTAssertNil(HotkeyConflictChecker.check(binding, for: .action(.openNotes), among: assignments).problem)
        XCTAssertEqual(HotkeyConflictChecker.check(.defaultAsk, for: .action(.openChat), among: assignments).problem,
                       .taken(.builtIn(.ask)))
        XCTAssertEqual(HotkeyConflictChecker.check(chord(17, .command), for: .builtIn(.history), among: assignments)
            .problem, .taken(.keyword(keywordID)))
    }

    func testOwnerOrderIsStable() throws {
        let binding = chord(15, [.control, .option])
        let first = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let assignments: [HotkeyTarget: HotkeyBinding] = [.keyword(second): binding, .keyword(first): binding,
                                                          .action(.openStudio): binding]
        XCTAssertEqual(HotkeyConflictChecker.owner(of: binding, excluding: .builtIn(.ask), among: assignments),
                       .action(.openStudio))
        XCTAssertEqual(HotkeyConflictChecker.owner(of: binding, excluding: .action(.openStudio), among: assignments),
                       .keyword(first))
    }

    func testCommonSystemShortcutsWarnButSave() {
        for binding in [chord(8, .command), chord(9, .command), chord(49, .control), chord(21, [.command, .shift])] {
            let result = HotkeyConflictChecker.check(binding, for: .action(.openChat), among: [:])
            XCTAssertTrue(result.overridesSystemShortcut, HotkeyFormat.display(binding))
            XCTAssertTrue(result.canSave)
        }
        XCTAssertFalse(HotkeyConflictChecker.isCommonSystemShortcut(chord(8, [.command, .option])))
    }
}
