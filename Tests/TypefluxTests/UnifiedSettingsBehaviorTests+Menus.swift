import AppKit
import Testing
@testable import Typeflux

@MainActor
extension UnifiedSettingsBehaviorTests {
    /// Identify the picker before opening it; SwiftUI fills NSMenu during native tracking.
    static func selectPopupItem(_ title: String, identifier: String = "personas.defaultSelection",
                                in window: NSWindow) throws {
        let popup = try nativePopup(identifier, in: window)
        let enabled = popup.isEnabled
        try #require(enabled, "The identified picker must be enabled: \(identifier)")
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        var selected = false
        var titles: [String] = []
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = popup.menu else { return }
                titles = menu.items.map(\.title)
                let item = menuItem(title, in: menu)
                // Always close the tracking loop, including when the requested option is absent.
                menu.cancelTrackingWithoutAnimation()
                if let (itemMenu, index) = item {
                    itemMenu.performActionForItem(at: index)
                    selected = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        popup.performClick(nil)
        try #require(selected, "Missing enabled item \(title) in \(identifier): \(titles)")
    }

    private static func nativePopup(_ identifier: String, in window: NSWindow) throws -> NSPopUpButton {
        let contentView = window.contentView
        let content = try #require(contentView)
        let controls = popupButtons(in: content)
        if let popup = controls.first(where: { $0.accessibilityIdentifier() == identifier }) {
            return popup
        }
        let matchingElement = SettingsBehaviorTestSupport.elements(in: content).first {
            $0.value("accessibilityIdentifier") as? String == identifier
        }
        let element = try #require(matchingElement, "Missing picker \(identifier)")
        // SwiftUI may expose an accessibility proxy rather than its underlying AppKit view.
        let matchingPopup = controls.first {
            element.frame.intersects(window.convertToScreen($0.convert($0.bounds, to: nil)))
        }
        return try #require(matchingPopup, "Missing native picker for \(identifier)")
    }

    private static func popupButtons(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popupButtons(in: $0) }
    }

    private static func menuItem(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() where item.isEnabled && !item.isHidden {
            if item.title == title, !item.isSeparatorItem {
                return (menu, index)
            }
            if let submenu = item.submenu, let match = menuItem(title, in: submenu) {
                return match
            }
        }
        return nil
    }
}
