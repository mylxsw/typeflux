import AppKit
import Testing
@testable import Typeflux

@MainActor
enum AskNotesToolbarTestSupport {
    static func chooseMode(_ mode: AskNotesViewModel.Mode, in window: NSWindow) throws {
        window.makeKeyAndOrderFront(nil)
        let more = try #require(AskLibraryTestSupport.elements(in: window).first {
            $0.value("accessibilityIdentifier") as? String == "ask.notes.more"
        })
        try choose(L("ask.notes.mode." + mode.rawValue)) {
            let point = window.convertPoint(fromScreen: NSPoint(x: more.frame.midX, y: more.frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            }
        }
    }

    private static func choose(_ title: String, opening openMenu: () throws -> Void) throws {
        var trackedMenu: NSMenu?
        var titles: [String] = []
        var selected = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { notification in
            MainActor.assumeIsolated { trackedMenu = notification.object as? NSMenu }
        }
        // SwiftUI creates the native menu items only when tracking begins.
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = trackedMenu else { return }
                titles = menu.items.map(\.title)
                let index = menu.items.firstIndex { $0.title == title && $0.isEnabled && !$0.isHidden }
                menu.cancelTrackingWithoutAnimation()
                if let index {
                    menu.performActionForItem(at: index)
                    selected = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer {
            timer.invalidate()
            NotificationCenter.default.removeObserver(observer)
            trackedMenu?.cancelTrackingWithoutAnimation()
        }
        try openMenu()
        try #require(selected, "Enabled native menu item \(title) missing from \(titles)")
    }
}
