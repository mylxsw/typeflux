import AppKit
import XCTest
@testable import Typeflux

final class HotkeyGestureArbiterTests: XCTestCase {
    private let activation = HotkeyBinding.defaultActivation
    private let ask = HotkeyBinding.defaultAsk
    private let persona = HotkeyBinding.defaultPersona

    func testModifierOnlyActivationWaitsForArbitrationBeforeBeginning() {
        var arbiter = HotkeyGestureArbiter()

        let events = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(arbiter.hasPendingModifierActivation)

        let timeoutEvents = arbiter.handlePendingModifierActivationTimeout()
        XCTAssertEqual(timeoutEvents, [.begin(.activation)])
        XCTAssertEqual(arbiter.phase, .active(.activation))
    }

    func testPendingModifierActivationCancelsWhenModifierIsReleasedEarly() {
        var arbiter = HotkeyGestureArbiter()
        _ = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )

        let releaseEvents = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: 0,
            activationHotkey: activation,
            askHotkey: ask
        )

        XCTAssertTrue(releaseEvents.isEmpty)
        XCTAssertEqual(arbiter.phase, .idle)
        XCTAssertTrue(arbiter.handlePendingModifierActivationTimeout().isEmpty)
    }

    func testAskShortcutWinsDuringModifierArbitrationWindow() {
        var arbiter = HotkeyGestureArbiter()
        _ = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )

        let askEvents = arbiter.handleKeyDown(
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        XCTAssertEqual(askEvents, [.begin(.ask)])
        XCTAssertEqual(arbiter.phase, .active(.ask))
    }

    func testAskEndsEvenIfModifierWasReleasedFirst() {
        var arbiter = HotkeyGestureArbiter()
        _ = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )
        _ = arbiter.handleKeyDown(
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        let askEnded = arbiter.handleKeyUp(
            keyCode: ask.keyCode,
            activationHotkey: activation,
            askHotkey: ask
        )

        XCTAssertEqual(askEnded, [.end(.ask)])
        XCTAssertEqual(arbiter.phase, .idle)
    }

    func testRegularNonModifierActivationStillBeginsImmediately() {
        var arbiter = HotkeyGestureArbiter()
        let activation = HotkeyBinding(keyCode: 37, modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue))
        let events = arbiter.handleKeyDown(
            keyCode: 37,
            modifierFlags: UInt(NSEvent.ModifierFlags.command.rawValue),
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        XCTAssertEqual(events, [.begin(.activation)])
        XCTAssertEqual(arbiter.phase, .active(.activation))
    }

    func testShouldConsumeAskSpaceKeyDownDuringChord() {
        let arbiter = HotkeyGestureArbiter()

        let shouldConsume = arbiter.shouldConsume(
            eventType: .keyDown,
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        XCTAssertTrue(shouldConsume)
    }

    func testShouldConsumeRepeatedAskSpaceWhileAskIsActive() {
        var arbiter = HotkeyGestureArbiter()
        _ = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )
        _ = arbiter.handleKeyDown(
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        let shouldConsume = arbiter.shouldConsume(
            eventType: .keyDown,
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        XCTAssertTrue(shouldConsume)
    }

    func testShouldConsumeModifierFlagsChangedForFunctionTrigger() {
        let arbiter = HotkeyGestureArbiter()

        let shouldConsume = arbiter.shouldConsume(
            eventType: .flagsChanged,
            keyCode: activation.keyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )

        XCTAssertTrue(shouldConsume)
    }
}
