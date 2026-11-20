import AppKit
import XCTest
@testable import Typeflux

@MainActor
final class EventTapHotkeyServiceTests: XCTestCase {
    func testFallbackRecognizesOptionSpaceWithModifierEvents() async throws {
        let suite = "EventTapHotkeyServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.askHotkey = HotkeyBinding(keyCode: 49, modifierFlags: NSEvent.ModifierFlags.option.rawValue)

        func event(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags,
                   timestamp: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                          timestamp: timestamp, windowNumber: 0, context: nil,
                                          characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: keyCode))
        }

        let optionDown = try event(.flagsChanged, keyCode: 58, flags: .option, timestamp: 1)
        let spaceDown = try event(.keyDown, keyCode: 49, flags: .option, timestamp: 2)
        let spaceUp = try event(.keyUp, keyCode: 49, flags: .option, timestamp: 3)
        let optionUp = try event(.flagsChanged, keyCode: 58, flags: [], timestamp: 4)

        for canConsume in [true, false] {
            let service = EventTapHotkeyService(settingsStore: settings)
            service.refreshBindings()
            defer { service.stop() }
            var callbacks: [String] = []
            service.onAskPressBegan = { _ in callbacks.append("begin") }
            service.onAskPressEnded = { callbacks.append("end") }

            XCTAssertFalse(service.processNSEvent(optionDown, canConsume: canConsume))
            XCTAssertEqual(service.processNSEvent(spaceDown, canConsume: canConsume), canConsume)
            XCTAssertEqual(service.processNSEvent(spaceUp, canConsume: canConsume), canConsume)
            XCTAssertFalse(service.processNSEvent(optionUp, canConsume: canConsume))

            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(callbacks, ["begin", "end"])
        }
    }
}
