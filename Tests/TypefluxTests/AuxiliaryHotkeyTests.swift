import AppKit
import SwiftUI
@testable import Typeflux
import XCTest

final class AuxiliaryHotkeyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        KeychainTokenStore.useInMemoryStoreForTesting = true
        KeychainTokenStore.clearAll()
    }

    override func tearDown() {
        KeychainTokenStore.clearAll()
        KeychainTokenStore.useInMemoryStoreForTesting = false
        super.tearDown()
    }

    private let doubleFnAsk = HotkeyBinding(
        keyCode: HotkeyBinding.functionKeyCode,
        modifierFlags: UInt(NSEvent.ModifierFlags.function.rawValue),
        pressCount: 2
    )
    private let fn = HotkeyBinding.modifierFlag(for: 63)
    private let shift = HotkeyBinding.modifierFlag(for: 56)

    private func flags(
        _ arbiter: inout HotkeyGestureArbiter, _ key: Int, _ value: UInt, _ time: Double,
        auxiliary: HotkeyBinding = .defaultAuxiliary, activation: HotkeyBinding? = .defaultActivation,
        ask: HotkeyBinding = .defaultAsk
    ) -> [HotkeyGestureEvent] {
        arbiter.handleFlagsChanged(
            keyCode: key, modifierFlags: value, activationHotkey: activation,
            askHotkey: ask, auxiliaryHotkey: auxiliary, timestamp: time
        )
    }

    func testFnBeginsImmediatelyThenChordPromotesWithoutCancellation() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertEqual(flags(&arbiter, 63, fn, 1), [.begin(.activation)])
        XCTAssertEqual(flags(&arbiter, 56, fn | shift, 1.05), [.auxiliaryPromoted])
        XCTAssertEqual(flags(&arbiter, 56, fn, 2), [.end(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 63, 0, 2.1), [])
    }

    func testShiftFirstBeginsAuxiliaryAndFnFirstReleaseDoesNotTapMain() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertEqual(flags(&arbiter, 56, shift, 1), [])
        XCTAssertEqual(flags(&arbiter, 63, fn | shift, 1.05), [.begin(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 63, shift, 2), [.end(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 56, 0, 2.1), [])
    }

    func testRightShiftDoesNotTriggerLeftShiftChord() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertEqual(flags(&arbiter, 60, shift, 1), [])
        XCTAssertFalse(flags(&arbiter, 63, fn | shift, 1.05).contains(.begin(.auxiliary)))
    }

    func testPromotionSurvivesServiceArbitrationTimeout() {
        var arbiter = HotkeyGestureArbiter()
        _ = flags(&arbiter, 63, fn, 1)
        _ = arbiter.handlePendingModifierActivationTimeout()
        XCTAssertEqual(flags(&arbiter, 56, fn | shift, 1.3), [.auxiliaryPromoted])
    }

    func testSettledMainRecordingCannotBePromoted() {
        var arbiter = HotkeyGestureArbiter()
        _ = flags(&arbiter, 63, fn, 1)
        _ = arbiter.handlePendingModifierActivationTimeout()
        arbiter.settleActivationGesture()
        XCTAssertEqual(flags(&arbiter, 56, fn | shift, 3), [])
    }

    func testFnDoubleTapStillStartsAsk() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertEqual(flags(&arbiter, 63, fn, 1, ask: doubleFnAsk), [.begin(.activation)])
        XCTAssertEqual(flags(&arbiter, 63, 0, 1.1, ask: doubleFnAsk), [.activationTapped])
        XCTAssertEqual(flags(&arbiter, 63, fn, 1.2, ask: doubleFnAsk), [.begin(.ask)])
    }

    func testIndependentModifierDoubleTapAndRelease() {
        var arbiter = HotkeyGestureArbiter()
        let auxiliary = HotkeyBinding.rightOptionAsk
        let option = auxiliary.modifierFlags
        XCTAssertEqual(flags(&arbiter, 61, option, 1, auxiliary: auxiliary), [])
        XCTAssertEqual(flags(&arbiter, 61, 0, 1.1, auxiliary: auxiliary), [])
        XCTAssertEqual(flags(&arbiter, 61, option, 1.2, auxiliary: auxiliary), [.begin(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 61, 0, 1.3, auxiliary: auxiliary), [.end(.auxiliary)])
    }

    func testSharedSingleKeyDoubleTapPromotesSameRecording() {
        var arbiter = HotkeyGestureArbiter()
        let single = HotkeyBinding.rightOptionActivation
        let double = HotkeyBinding.rightOptionAsk
        XCTAssertEqual(flags(&arbiter, 61, single.modifierFlags, 1, auxiliary: double, activation: single), [.begin(.activation)])
        _ = flags(&arbiter, 61, 0, 1.1, auxiliary: double, activation: single)
        XCTAssertEqual(flags(&arbiter, 61, single.modifierFlags, 1.2, auxiliary: double, activation: single), [.auxiliaryPromoted])
    }

    func testOrdinarySingleKeyAndCombination() {
        for binding in [HotkeyBinding(keyCode: 49, modifierFlags: 0), HotkeyBinding(keyCode: 18, modifierFlags: fn)] {
            var arbiter = HotkeyGestureArbiter()
            XCTAssertEqual(arbiter.handleKeyDown(
                keyCode: binding.keyCode, modifierFlags: binding.modifierFlags, isRepeat: false,
                activationHotkey: nil, askHotkey: nil, personaHotkey: nil, auxiliaryHotkey: binding
            ), [.begin(.auxiliary)])
            XCTAssertEqual(arbiter.handleKeyUp(
                keyCode: binding.keyCode, activationHotkey: nil, askHotkey: nil, auxiliaryHotkey: binding
            ), [.end(.auxiliary)])
        }
    }

    func testOrdinarySingleKeyDoubleTap() {
        var arbiter = HotkeyGestureArbiter()
        let binding = HotkeyBinding(keyCode: 49, modifierFlags: 0, pressCount: 2)
        for (time, expected) in [(1.0, [HotkeyGestureEvent]()), (1.2, [.begin(.auxiliary)])] {
            XCTAssertEqual(arbiter.handleKeyDown(
                keyCode: 49, modifierFlags: 0, isRepeat: false, activationHotkey: nil,
                askHotkey: nil, personaHotkey: nil, auxiliaryHotkey: binding, timestamp: time
            ), expected)
            _ = arbiter.handleKeyUp(keyCode: 49, activationHotkey: nil, askHotkey: nil, auxiliaryHotkey: binding, timestamp: time + 0.05)
        }
    }

    func testChordCaptureWorksInBothOrdersAndMatchesDefault() {
        for keys in [[63, 56], [56, 63]] {
            var capture = AuxiliaryHotkeyCapture()
            _ = capture.handle(type: .flagsChanged, keyCode: keys[0], flags: HotkeyBinding.modifierFlag(for: keys[0]), isRepeat: false, timestamp: 1)
            let value = capture.handle(type: .flagsChanged, keyCode: keys[1], flags: fn | shift, isRepeat: false, timestamp: 1.1)
            XCTAssertEqual(value?.signature, HotkeyBinding.defaultAuxiliary.signature)
        }
        XCTAssertEqual(HotkeyFormat.components(.defaultAuxiliary), ["Fn", "⇧(L)"])
    }

    func testDoubleTapCaptureRequiresRelease() {
        var capture = AuxiliaryHotkeyCapture()
        _ = capture.handle(type: .keyDown, keyCode: 49, flags: 0, isRepeat: false, timestamp: 1)
        XCTAssertNil(capture.handle(type: .keyDown, keyCode: 49, flags: 0, isRepeat: true, timestamp: 1.01))
        _ = capture.handle(type: .keyUp, keyCode: 49, flags: 0, isRepeat: false, timestamp: 1.1)
        XCTAssertEqual(capture.handle(type: .keyDown, keyCode: 49, flags: 0, isRepeat: false, timestamp: 1.2)?.pressCount, 2)
    }

    func testSettingsPersistAndDeletedPersonaFallsBackWithoutChangingMain() throws {
        let name = "AuxiliaryHotkeyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.auxiliaryHotkey?.signature, HotkeyBinding.defaultAuxiliary.signature)
        XCTAssertEqual(settings.auxiliaryPersona.id, SettingsStore.englishPersonaID)
        let custom = PersonaProfile(name: "Custom", prompt: "Test")
        settings.personas = settings.personas + [custom]
        settings.auxiliaryPersonaID = custom.id.uuidString
        settings.applyPersonaSelection(SettingsStore.defaultPersonaID)
        settings.auxiliaryHotkey = .rightOptionActivation
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.auxiliaryPersona.id, custom.id)
        XCTAssertEqual(reopened.auxiliaryHotkey?.signature, HotkeyBinding.rightOptionActivation.signature)
        reopened.personas = []
        XCTAssertEqual(reopened.auxiliaryPersona.id, SettingsStore.englishPersonaID)
        XCTAssertEqual(reopened.activePersonaID, SettingsStore.defaultPersonaID.uuidString)
        reopened.auxiliaryHotkey = nil
        XCTAssertNil(settings.auxiliaryHotkey)
    }

    func testDefaultDoesNotStealExistingLegacyChord() throws {
        let name = "AuxiliaryHotkeyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.historyHotkey = HotkeyBinding(keyCode: 56, modifierFlags: fn | shift)
        XCTAssertNil(settings.auxiliaryHotkey)
    }

    @MainActor
    func testOnboardingReplacementAndRestoreIncludeAuxiliary() throws {
        let name = "AuxiliaryHotkeyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
        model.useExternalKeyboardShortcutReplacement(.rightCommand)
        XCTAssertEqual(settings.auxiliaryHotkey?.signature, HotkeyBinding.auxiliaryChord(baseKeyCode: 54).signature)
        model.restoreDefaultFNShortcuts()
        XCTAssertEqual(settings.auxiliaryHotkey?.signature, HotkeyBinding.defaultAuxiliary.signature)
    }

    @MainActor
    func testOnboardingPreservesCustomAuxiliaryAndRejectsConflict() throws {
        let name = "AuxiliaryHotkeyTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.auxiliaryHotkey = .rightOptionActivation
        let model = OnboardingViewModel(settingsStore: settings, onComplete: {})
        model.useExternalKeyboardShortcutReplacement(.rightCommand)
        XCTAssertEqual(settings.auxiliaryHotkey?.signature, HotkeyBinding.rightOptionActivation.signature)
        model.useExternalKeyboardShortcutReplacement(.rightOption)
        XCTAssertTrue(model.shortcutReplacementConflict)
        XCTAssertEqual(settings.activationHotkey?.signature, HotkeyBinding.rightCommandActivation.signature)
    }
}


extension AuxiliaryHotkeyTests {
    func testAskDoubleTapSharingAuxiliarySingleKeyStillWins() {
        var arbiter = HotkeyGestureArbiter()
        let binding = HotkeyBinding.defaultActivation
        let fn = binding.modifierFlags
        XCTAssertEqual(flags(&arbiter, 63, fn, 1, auxiliary: binding, activation: .rightOptionActivation, ask: doubleFnAsk), [.begin(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 63, 0, 1.1, auxiliary: binding, activation: .rightOptionActivation, ask: doubleFnAsk), [.end(.auxiliary)])
        XCTAssertEqual(flags(&arbiter, 63, fn, 1.2, auxiliary: binding, activation: .rightOptionActivation, ask: doubleFnAsk), [.begin(.ask)])
    }

    func testExternalKeyboardChordsDistinguishRightAndLeftModifiers() {
        let right = HotkeyBinding.auxiliaryChord(baseKeyCode: 54)
        for (key, expected) in [(54, [HotkeyGestureEvent.begin(.auxiliary)]), (55, [])] {
            var arbiter = HotkeyGestureArbiter()
            _ = flags(&arbiter, 56, shift, 1, auxiliary: right, activation: nil)
            XCTAssertEqual(flags(&arbiter, key, right.modifierFlags, 1.1, auxiliary: right, activation: nil), expected)
        }
    }

    @MainActor
    func testOnboardingRendersAuxiliaryAtCompactAndRegularSizes() throws {
        let name = "AuxiliaryHotkeyTests.render.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = OnboardingViewModel(settingsStore: SettingsStore(defaults: defaults), onComplete: {})
        model.currentStep = .shortcuts
        for size in [CGSize(width: 920, height: 680), CGSize(width: 1100, height: 820)] {
            let view = OnboardingView(viewModel: model, appearanceMode: .light)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/typeflux-aux-onboarding-\(Int(size.width)).png"))
            XCTAssertEqual(host.frame.size, size)
        }
    }
}


extension AuxiliaryHotkeyTests {
    func testDefaultAuxiliaryDoesNotConsumeOrdinaryShiftTyping() {
        var arbiter = HotkeyGestureArbiter()
        XCTAssertFalse(arbiter.shouldConsume(
            eventType: .flagsChanged, keyCode: 56, modifierFlags: shift,
            activationHotkey: .defaultActivation, askHotkey: .defaultAsk,
            personaHotkey: .defaultPersona, auxiliaryHotkey: .defaultAuxiliary
        ))
        _ = flags(&arbiter, 63, fn, 1)
        XCTAssertTrue(arbiter.shouldConsume(
            eventType: .flagsChanged, keyCode: 56, modifierFlags: fn | shift,
            activationHotkey: .defaultActivation, askHotkey: .defaultAsk,
            personaHotkey: .defaultPersona, auxiliaryHotkey: .defaultAuxiliary
        ))
        XCTAssertFalse(arbiter.shouldConsume(
            eventType: .keyDown, keyCode: 0, modifierFlags: shift,
            activationHotkey: .defaultActivation, askHotkey: .defaultAsk,
            personaHotkey: .defaultPersona, auxiliaryHotkey: .defaultAuxiliary
        ))
    }
}


extension AuxiliaryHotkeyTests {
    func testShiftFirstReleaseIsNotSwallowedAfterChord() {
        var arbiter = HotkeyGestureArbiter()
        _ = flags(&arbiter, 56, shift, 1)
        _ = flags(&arbiter, 63, fn | shift, 1.1)
        XCTAssertFalse(arbiter.shouldConsume(
            eventType: .flagsChanged, keyCode: 56, modifierFlags: fn,
            activationHotkey: .defaultActivation, askHotkey: .defaultAsk,
            personaHotkey: .defaultPersona, auxiliaryHotkey: .defaultAuxiliary
        ))
    }
}
