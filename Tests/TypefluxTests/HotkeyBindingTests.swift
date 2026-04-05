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

    // MARK: - signature

    func testSignatureFormat() {
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 1_048_576)
        XCTAssertEqual(binding.signature, "49:1048576")
    }

    // MARK: - isRightCommandTrigger

    func testIsRightCommandTrigger() {
        let binding = HotkeyBinding(keyCode: 54, modifierFlags: 1_048_576)
        XCTAssertTrue(binding.isRightCommandTrigger)
    }

    func testIsNotRightCommandTriggerWrongKeyCode() {
        let binding = HotkeyBinding(keyCode: 55, modifierFlags: 1_048_576)
        XCTAssertFalse(binding.isRightCommandTrigger)
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

    // MARK: - isModifierOnlyTrigger

    func testModifierOnlyForFn() {
        XCTAssertTrue(HotkeyBinding.defaultActivation.isModifierOnlyTrigger)
    }

    func testModifierOnlyForRightCommand() {
        let binding = HotkeyBinding(keyCode: 54, modifierFlags: 1_048_576)
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

    func testDefaultAskIsSpaceWithFn() {
        XCTAssertEqual(HotkeyBinding.defaultAsk.keyCode, 49)
    }

    func testDefaultPersonaIsPKey() {
        XCTAssertEqual(HotkeyBinding.defaultPersona.keyCode, 35)
    }

    func testFunctionKeyCodeConstant() {
        XCTAssertEqual(HotkeyBinding.functionKeyCode, 63)
    }
}
