@testable import Typeflux
import XCTest

final class HotkeyBindingTests: XCTestCase {
    // MARK: - matches()

    func testMatchesExact() {
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertTrue(binding.matches(keyCode: 49, modifierFlags: 1_048_576))
    }

    func testMatchesFailsOnDifferentKeyCode() {
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertFalse(binding.matches(keyCode: 50, modifierFlags: 1_048_576))
    }

    func testMatchesFailsOnDifferentModifiers() {
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertFalse(binding.matches(keyCode: 49, modifierFlags: 0))
    }

    func testMatchesDoesNotTreatDoubleTapAsSinglePress() {
        let binding = HotkeyBinding(keyCode: HotkeyBinding.functionKeyCode, modifierFlags: 1_048_576, pressCount: 2)
        XCTAssertFalse(binding.matches(keyCode: HotkeyBinding.functionKeyCode, modifierFlags: 1_048_576))
    }

    // MARK: - signature

    func testSignatureFormat() {
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertEqual(binding.signature, "49:1048576:1")
    }

    func testSignatureIncludesDoubleTapPressCount() {
        let binding = HotkeyBinding(keyCode: HotkeyBinding.functionKeyCode, modifierFlags: 1_048_576, pressCount: 2)
        XCTAssertEqual(binding.signature, "63:1048576:2")
    }

    // MARK: - isRightCommandTrigger

    func testIsRightCommandTrigger() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightCommandKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
        )
        XCTAssertTrue(binding.isRightCommandTrigger)
    }

    func testIsNotRightCommandTriggerWrongKeyCode() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightCommandKeyCode + 1,
            modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
        )
        XCTAssertFalse(binding.isRightCommandTrigger)
    }

    // MARK: - isRightOptionTrigger

    func testIsRightOptionTrigger() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightOptionKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue)
        )
        XCTAssertTrue(binding.isRightOptionTrigger)
    }

    func testIsNotRightOptionTriggerWrongKeyCode() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightOptionKeyCode + 1,
            modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue)
        )
        XCTAssertFalse(binding.isRightOptionTrigger)
    }

    // MARK: - isFunctionTrigger

    func testIsFunctionTrigger() {
        let binding = HotkeyBinding.defaultActivation
        XCTAssertTrue(binding.isFunctionTrigger)
    }

    func testIsNotFunctionTriggerWrongKeyCode() {
        let binding = HotkeyBinding(keyCode: 0, modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue))
        XCTAssertFalse(binding.isFunctionTrigger)
    }

    func testIsFunctionDoubleTapTrigger() {
        let doubleFn = HotkeyBinding(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue),
            pressCount: 2
        )
        XCTAssertTrue(doubleFn.isModifierDoubleTapTrigger)
        XCTAssertFalse(HotkeyBinding.defaultActivation.isModifierDoubleTapTrigger)
        XCTAssertTrue(HotkeyBinding.rightCommandAsk.isModifierDoubleTapTrigger)
        XCTAssertTrue(HotkeyBinding.rightOptionAsk.isModifierDoubleTapTrigger)
    }

    // MARK: - isModifierOnlyTrigger

    func testModifierOnlyForFn() {
        XCTAssertTrue(HotkeyBinding.defaultActivation.isModifierOnlyTrigger)
    }

    func testModifierOnlyForRightCommand() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightCommandKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue)
        )
        XCTAssertTrue(binding.isModifierOnlyTrigger)
    }

    func testModifierOnlyForRightOption() {
        let binding = HotkeyBinding(
            keyCode: HotkeyBinding.rightOptionKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue)
        )
        XCTAssertTrue(binding.isModifierOnlyTrigger)
    }

    func testNotModifierOnlyForRegularKey() {
        let binding = HotkeyBinding(keyCode: 0, modifierFlags: 1_048_576)
        XCTAssertFalse(binding.isModifierOnlyTrigger)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = HotkeyBinding(keyCode: 35, modifierFlags: 1_572_864)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.keyCode, 35)
        XCTAssertEqual(decoded.modifierFlags, 1_572_864)
    }

    // MARK: - Equatable

    func testEquality() {
        let id = UUID()
        let a = HotkeyBinding(id: id, keyCode: 49, modifierFlags: 1_048_576)
        let b = HotkeyBinding(id: id, keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentKeyCode() {
        let id = UUID()
        let a = HotkeyBinding(id: id, keyCode: 49, modifierFlags: 1_048_576)
        let b = HotkeyBinding(id: id, keyCode: 50, modifierFlags: 1_048_576)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Static defaults

    func testDefaultActivationIsFnKey() {
        XCTAssertEqual(HotkeyBinding.defaultActivation.keyCode, HotkeyBinding.functionKeyCode)
        XCTAssertTrue(HotkeyBinding.defaultActivation.isFunctionTrigger)
    }

    func testDefaultAskIsCommandSpace() {
        XCTAssertEqual(HotkeyBinding.defaultAsk.keyCode, 49)
        XCTAssertEqual(HotkeyBinding.defaultAsk.modifierFlags, UInt(NSEvent.ModifierFlags.command.rawValue))
        XCTAssertEqual(HotkeyBinding.defaultAsk.pressCount ?? 1, 1)
        XCTAssertFalse(HotkeyBinding.defaultAsk.isModifierOnlyTrigger)
        XCTAssertFalse(HotkeyBinding.defaultAsk.isModifierDoubleTapTrigger)
    }

    func testDefaultPersonaIsPKey() {
        XCTAssertEqual(HotkeyBinding.defaultPersona.keyCode, 35)
    }

    func testFunctionKeyCodeConstant() {
        XCTAssertEqual(HotkeyBinding.functionKeyCode, 63)
    }
}
