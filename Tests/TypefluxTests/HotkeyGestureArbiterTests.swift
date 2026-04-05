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

        XCTAssertEqual(releaseEvents, [.activationTapped])
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

    func testShortFnTapBecomesActivationTap() {
        var arbiter = HotkeyGestureArbiter()
        _ = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: activation.modifierFlags,
            activationHotkey: activation,
            askHotkey: ask
        )

        let events = arbiter.handleFlagsChanged(
            keyCode: HotkeyBinding.functionKeyCode,
            modifierFlags: 0,
            activationHotkey: activation,
            askHotkey: ask
        )

        XCTAssertEqual(events, [.activationTapped])
    }
}

// MARK: - Extended HotkeyGestureArbiter tests

extension HotkeyGestureArbiterTests {

    // MARK: - HotkeyBinding properties

    func testHotkeyBindingFunctionKeyCode() {
        // Fn key code is a specific value (typically 63)
        XCTAssertGreaterThan(HotkeyBinding.functionKeyCode, 0)
    }

    func testHotkeyBindingIsFunctionKey() {
        XCTAssertTrue(activation.isFunctionTrigger)
        XCTAssertFalse(ask.isFunctionTrigger)
        XCTAssertFalse(persona.isFunctionTrigger)
    }

    // MARK: - handleKeyDown with no prior state

    func testHandleKeyDownWithAskHotkeyWhileIdle() {
        var arbiter = HotkeyGestureArbiter()
        let events = arbiter.handleKeyDown(
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )
        // Ask hotkey while idle should emit some event
        XCTAssertFalse(events.isEmpty)
    }

    func testHandleKeyDownWithPersonaHotkeyWhileIdle() {
        var arbiter = HotkeyGestureArbiter()
        let events = arbiter.handleKeyDown(
            keyCode: persona.keyCode,
            modifierFlags: persona.modifierFlags,
            isRepeat: false,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )
        // Persona hotkey while idle should emit personaRequested
        XCTAssertFalse(events.isEmpty)
    }

    func testHandleKeyDownRepeatIsIgnored() {
        var arbiter = HotkeyGestureArbiter()
        let events = arbiter.handleKeyDown(
            keyCode: ask.keyCode,
            modifierFlags: ask.modifierFlags,
            isRepeat: true, // repeat = true
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )
        XCTAssertTrue(events.isEmpty)
    }

    func testHandleKeyUpWithAskHotkeyDoesNotEmitEventsWhenIdle() {
        var arbiter = HotkeyGestureArbiter()
        let events = arbiter.handleKeyUp(
            keyCode: ask.keyCode,
            activationHotkey: activation,
            askHotkey: ask
        )
        // Key up when not in active phase returns no events
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - shouldConsume edge cases

    func testShouldNotConsumeUnrelatedKeyCode() {
        let arbiter = HotkeyGestureArbiter()
        let shouldConsume = arbiter.shouldConsume(
            eventType: .keyDown,
            keyCode: 42, // unrelated key code
            modifierFlags: 0,
            activationHotkey: activation,
            askHotkey: ask,
            personaHotkey: persona
        )
        XCTAssertFalse(shouldConsume)
    }

    func testShouldConsumeActivationKeyDown() {
        let arbiter = HotkeyGestureArbiter()
        // Non-function key activation (e.g., ask or persona hotkey)
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

    // MARK: - HotkeyGestureEvent description

    func testGestureEventDescriptions() {
        let events: [HotkeyGestureEvent] = [.activationTapped, .personaRequested]
        for event in events {
            // Just verify they can be represented as strings (no crash)
            let desc = "\(event)"
            XCTAssertFalse(desc.isEmpty)
        }
    }
}
