import AppKit
@testable import Typeflux
import XCTest

final class RingModifierHotkeyTests: XCTestCase {
    private let modifierKeys = [54, 55, 56, 60, 58, 61, 59, 62, 63]

    func testEveryPhysicalModifierCanBeRecordedAndTriggersOnePressAndRelease() throws {
        for key in modifierKeys {
            let flag = HotkeyBinding.modifierFlag(for: key)
            var capture = AuxiliaryHotkeyCapture()
            let binding = capture.handle(type: .flagsChanged, keyCode: key, flags: flag,
                                         isRepeat: false, timestamp: 1)
            XCTAssertEqual(binding?.keyCode, key)
            XCTAssertEqual(binding?.isSingleModifierTrigger, true)
            XCTAssertTrue(try HotkeyConflictChecker.check(XCTUnwrap(binding), for: .action(.ring), among: [:]).canSave)
            XCTAssertFalse(try SystemHotkeyPool.canRegister(XCTUnwrap(binding)))
            var tracker = RingModifierHotkey()
            XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: key, flags: flag, binding: binding), .began)
            XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: key, flags: 0, binding: binding), .ended)
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: key, flags: 0, binding: binding))
        }
    }

    func testRegularShortcutCancelsWithoutRunningOnReleaseAndNextPressWorks() {
        let binding = HotkeyBinding.rightCommandActivation
        var tracker = RingModifierHotkey()
        XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: 54, flags: binding.modifierFlags,
                                      binding: binding), .began)
        XCTAssertEqual(tracker.handle(type: .keyDown, keyCode: 8, flags: binding.modifierFlags,
                                      binding: binding), .cancelled)
        XCTAssertNil(tracker.handle(type: .keyDown, keyCode: 8, flags: binding.modifierFlags, binding: binding))
        XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 54, flags: 0, binding: binding))
        XCTAssertNil(tracker.handle(type: .keyUp, keyCode: 8, flags: 0, binding: binding))
        XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: 54, flags: binding.modifierFlags,
                                      binding: binding), .began)
    }

    func testModifierPressedWhileTypingDoesNotOpenRing() {
        var tracker = RingModifierHotkey()
        let binding = HotkeyBinding.rightOptionActivation
        XCTAssertNil(tracker.handle(type: .keyDown, keyCode: 0, flags: 0, binding: binding))
        XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 61, flags: binding.modifierFlags, binding: binding))
        XCTAssertNil(tracker.handle(type: .keyUp, keyCode: 0, flags: binding.modifierFlags, binding: binding))
        XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 61, flags: 0, binding: binding))
    }

    func testOtherModifiersCancelInEitherOrderIncludingOppositeSide() {
        let binding = HotkeyBinding.rightCommandActivation
        for other in [55, 56, 61] {
            var tracker = RingModifierHotkey()
            let otherFlag = HotkeyBinding.modifierFlag(for: other)
            XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: 54, flags: binding.modifierFlags,
                                          binding: binding), .began)
            XCTAssertEqual(tracker.handle(type: .flagsChanged, keyCode: other,
                                          flags: binding.modifierFlags | otherFlag, binding: binding), .cancelled)
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 54, flags: otherFlag, binding: binding))
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: other, flags: 0, binding: binding))
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: other, flags: otherFlag, binding: binding))
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 54,
                                        flags: binding.modifierFlags | otherFlag, binding: binding))
        }
    }

    func testDisabledAndOrdinaryChordBindingsDoNotTrigger() {
        for binding in [nil, RingConfiguration.defaultHotkey, HotkeyBinding.rightOptionAsk] {
            var tracker = RingModifierHotkey()
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 61,
                                        flags: HotkeyBinding.modifierFlag(for: 61), binding: binding))
            XCTAssertNil(tracker.handle(type: .flagsChanged, keyCode: 61, flags: 0, binding: binding))
        }
    }

    func testRingSingleModifierConflictsWithSingleAndDoubleTapInBothDirections() {
        for other in [HotkeyBinding.rightOptionActivation, .rightOptionAsk] {
            let ring = HotkeyBinding.rightOptionActivation
            XCTAssertEqual(HotkeyConflictChecker.check(ring, for: .action(.ring),
                                                       among: [.builtIn(.ask): other]).problem, .taken(.builtIn(.ask)))
            XCTAssertEqual(HotkeyConflictChecker.check(other, for: .builtIn(.ask),
                                                       among: [.action(.ring): ring]).problem, .taken(.action(.ring)))
        }
        XCTAssertNil(HotkeyConflictChecker.check(.rightCommandActivation, for: .action(.ring),
                                                 among: [.builtIn(.activation): .defaultActivation]).problem)
    }

    func testRingDoesNotAllowDoubleTapModifierChordOrUnmodifiedTypingKeys() {
        for binding in [HotkeyBinding.rightOptionAsk, .defaultAuxiliary] {
            XCTAssertEqual(HotkeyConflictChecker.check(binding, for: .action(.ring), among: [:]).problem, .gesture)
        }
        XCTAssertEqual(HotkeyConflictChecker.check(HotkeyBinding(keyCode: 0, modifierFlags: 0),
                                                   for: .action(.ring), among: [:]).problem, .needsModifier)
    }
}
