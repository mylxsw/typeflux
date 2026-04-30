import AppKit
@testable import Typeflux
import XCTest

final class HotkeyRecorderTests: XCTestCase {
    func testIgnoresSingleNonModifierKeyDownWithoutModifiers() {
        let binding = HotkeyRecorder.recordedBinding(
            eventType: .keyDown,
            keyCode: 49,
            modifierFlags: 0,
            isRepeat: false,
        )

        XCTAssertNil(binding)
    }

    func testRecordsKeyDownWithModifiers() {
        let flags = UInt(NSEvent.ModifierFlags.command.rawValue)

        let binding = HotkeyRecorder.recordedBinding(
            eventType: .keyDown,
            keyCode: 35,
            modifierFlags: flags,
            isRepeat: false,
        )

        XCTAssertEqual(binding?.keyCode, 35)
        XCTAssertEqual(binding?.modifierFlags, flags)
    }

    func testIgnoresRepeatedKeyDown() {
        let binding = HotkeyRecorder.recordedBinding(
            eventType: .keyDown,
            keyCode: 49,
            modifierFlags: 0,
            isRepeat: true,
        )

        XCTAssertNil(binding)
    }

    func testRecordsSupportedModifierOnlyTriggerFromFlagsChanged() {
        let binding = HotkeyRecorder.recordedBinding(
            eventType: .flagsChanged,
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue),
            isRepeat: false,
        )

        XCTAssertEqual(binding?.keyCode, HotkeyBinding.defaultActivation.keyCode)
        XCTAssertEqual(binding?.modifierFlags, HotkeyBinding.defaultActivation.modifierFlags)
    }

    func testRecordsRightOptionModifierOnlyTriggerFromFlagsChanged() {
        let binding = HotkeyRecorder.recordedBinding(
            eventType: .flagsChanged,
            keyCode: HotkeyBinding.rightOptionKeyCode,
            modifierFlags: UInt(NSEvent.ModifierFlags.option.rawValue),
            isRepeat: false,
        )

        XCTAssertEqual(binding?.keyCode, HotkeyBinding.rightOptionKeyCode)
        XCTAssertEqual(binding?.modifierFlags, UInt(NSEvent.ModifierFlags.option.rawValue))
    }

    func testIgnoresUnsupportedModifierOnlyTriggerFromFlagsChanged() {
        let binding = HotkeyRecorder.recordedBinding(
            eventType: .flagsChanged,
            keyCode: 56,
            modifierFlags: UInt(NSEvent.ModifierFlags.shift.rawValue),
            isRepeat: false,
        )

        XCTAssertNil(binding)
    }
}
