import AppKit
import XCTest
@testable import Typeflux

@MainActor
final class RecordingFeatureHotkeyTests: XCTestCase {
    func testFeaturesDuringLockedAndHeldRecordingPreserveVoiceReleaseAndStop() async {
        for held in [false, true] {
            let name = "RecordingFeatureHotkeyTests-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let settings = SettingsStore(defaults: defaults)
            let voice = HotkeyBinding(keyCode: 49, modifierFlags: 0)
            settings.activationHotkey = voice
            let service = EventTapHotkeyService(settingsStore: settings)
            service.refreshBindings()
            defer { service.stop() }
            var recording = false
            var events: [String] = []
            service.recordingStopEnabled = { recording }
            service.onActivationPressBegan = { _ in events.append("begin") }
            service.onActivationPressEnded = { _ in events.append("release") }
            service.onActivationCancelled = { events.append("cancel") }
            service.onRecordingStop = { events.append("stop") }
            service.onHistoryRequested = { events.append("clipboard") }
            service.onScreenshotRequested = { events.append("screenshot") }
            var time = 1.0
            @discardableResult
            func send(_ type: HotkeyPhysicalEventType, _ key: Int, _ flags: UInt, repeated: Bool = false) -> Bool {
                time += 0.01
                return service.processPhysicalEvent(eventType: type, keyCode: key, modifierFlags: flags,
                    isRepeat: repeated, canConsume: true, timestamp: time)
            }
            _ = send(.keyDown, voice.keyCode, 0)
            if !held { _ = send(.keyUp, voice.keyCode, 0) }
            recording = true
            for binding in [settings.screenshotHotkey!, settings.historyHotkey!] {
                _ = send(.flagsChanged, 55, binding.modifierFlags)
                XCTAssertTrue(send(.keyDown, binding.keyCode, binding.modifierFlags))
                _ = send(.keyDown, binding.keyCode, binding.modifierFlags, repeated: true)
                _ = send(.keyUp, binding.keyCode, binding.modifierFlags)
                _ = send(.flagsChanged, 55, 0)
            }
            XCTAssertFalse(send(.keyDown, 7, 0), "ordinary typing still passes through")
            _ = send(.keyUp, 7, 0)
            await drainCallbacks()
            XCTAssertEqual(events, held ? ["begin", "screenshot", "clipboard"] : ["begin", "release", "screenshot", "clipboard"])
            if held { _ = send(.keyUp, voice.keyCode, 0) }
            else { XCTAssertTrue(send(.keyDown, voice.keyCode, 0)) }
            await drainCallbacks()
            XCTAssertEqual(events.last, held ? "release" : "stop")
            XCTAssertFalse(events.contains("cancel"))
        }
    }

    func testModifierFeatureShortcutOnlyFiresOnPressWhileRecording() async {
        let name = "RecordingFeatureHotkeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.historyHotkey = .rightOptionActivation
        let service = EventTapHotkeyService(settingsStore: settings)
        service.refreshBindings()
        defer { service.stop() }
        service.recordingStopEnabled = { true }
        var requests = 0
        var stops = 0
        service.onHistoryRequested = { requests += 1 }
        service.onRecordingStop = { stops += 1 }
        for (time, flags) in [(1.0, HotkeyBinding.rightOptionActivation.modifierFlags), (1.1, UInt(0))] {
            _ = service.processPhysicalEvent(eventType: .flagsChanged, keyCode: 61, modifierFlags: flags,
                isRepeat: false, canConsume: true, timestamp: time)
        }
        await drainCallbacks()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(stops, 0)
    }

    func testHeldFnAllowsFeatureChordsAndOnlyFnReleaseEndsVoice() async {
        let name = "RecordingFeatureHotkeyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.activationHotkey = .defaultActivation
        settings.askHotkey = nil
        settings.auxiliaryHotkey = nil
        let service = EventTapHotkeyService(settingsStore: settings)
        service.refreshBindings()
        defer { service.stop() }
        var recording = false
        var events: [String] = []
        service.recordingStopEnabled = { recording }
        service.onActivationPressBegan = { _ in events.append("begin") }
        service.onActivationPressEnded = { _ in events.append("release") }
        service.onActivationCancelled = { events.append("cancel") }
        service.onRecordingStop = { events.append("stop") }
        service.onHistoryRequested = { events.append("clipboard") }
        service.onScreenshotRequested = { events.append("screenshot") }
        let fn = HotkeyBinding.defaultActivation.modifierFlags
        var time = 1.0
        @discardableResult
        func send(_ type: HotkeyPhysicalEventType, _ key: Int, _ flags: UInt) -> Bool {
            time += 0.01
            return service.processPhysicalEvent(eventType: type, keyCode: key, modifierFlags: flags,
                isRepeat: false, canConsume: true, timestamp: time)
        }
        send(.flagsChanged, 63, fn)
        recording = true
        for binding in [settings.screenshotHotkey!, settings.historyHotkey!] {
            send(.flagsChanged, 55, binding.modifierFlags | fn)
            XCTAssertTrue(send(.keyDown, binding.keyCode, binding.modifierFlags | fn))
            XCTAssertTrue(service.processPhysicalEvent(eventType: .keyDown, keyCode: binding.keyCode,
                modifierFlags: binding.modifierFlags | fn, isRepeat: true, canConsume: true, timestamp: time))
            send(.keyUp, binding.keyCode, binding.modifierFlags | fn)
            send(.flagsChanged, 55, fn)
        }
        await drainCallbacks()
        XCTAssertEqual(events, ["begin", "screenshot", "clipboard"])
        send(.flagsChanged, 63, 0)
        await drainCallbacks()
        XCTAssertEqual(events, ["begin", "screenshot", "clipboard", "release"])
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
