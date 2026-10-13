import AppKit
import Testing

/// Native controls can consume mouse-up inside a synchronous mouse-down tracking loop.
@MainActor
enum AskWorkspaceTestMouse {
    static func click(at point: NSPoint, in window: NSWindow) throws {
        let press = try event(.leftMouseDown, at: point, in: window)
        let release = try event(.leftMouseUp, at: point, in: window)
        // The release must already be queued when AppKit starts tracking the press.
        NSApp.postEvent(release, atStart: true)
        NSApp.sendEvent(press)
        // SwiftUI's nontracking controls leave the release queued. Deliver only our
        // own event, without waiting or dispatching it twice after native tracking.
        if removeIfQueued(release, matching: .leftMouseUp) {
            NSApp.sendEvent(release)
        }
    }

    @discardableResult
    static func removeIfQueued(_ event: NSEvent, matching mask: NSEvent.EventTypeMask) -> Bool {
        guard NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: false) === event
        else { return false }
        _ = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true)
        return true
    }

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}
