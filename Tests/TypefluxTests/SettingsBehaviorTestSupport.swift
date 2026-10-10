import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
enum SettingsBehaviorTestSupport {
    private typealias Press = @convention(c) (AnyObject, Selector) -> Bool

    struct Element {
        let object: NSObject

        func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }

        var label: String {
            value("accessibilityLabel") as? String ?? ""
        }

        var text: String {
            value("accessibilityValue") as? String ?? label
        }

        var role: String {
            value("accessibilityRole") as? String ?? ""
        }

        var frame: NSRect {
            (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        }

        func press() throws {
            if let button = object as? NSButton {
                button.performClick(nil)
                return
            }
            if let cell = object as? NSButtonCell {
                cell.performClick(nil)
                return
            }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            _ = try #require(object.responds(to: selector), "The rendered control must expose a press action")
            let press = unsafeBitCast(object.method(for: selector), to: Press.self)
            #expect(press(object, selector))
        }
    }

    static func elements(in root: Any) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> [Element] {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = Element(object: object)
            return [element] + (element.value("accessibilityChildren") as? [Any] ?? []).flatMap(walk)
        }
        return walk(root)
    }

    static func button(_ title: String, in root: Any) throws -> Element {
        try #require(elements(in: root).first { $0.role == NSAccessibility.Role.button.rawValue && $0.label == title },
                     "Missing rendered button: \(title)")
    }

    static func contains(_ text: String, in root: Any) -> Bool {
        elements(in: root).contains { $0.text == text || $0.label == text }
    }

    static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("The expected UI state did not become ready within three seconds")
                throw ReadinessTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func withFixture(_ check: (SettingsStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAccessibility = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        let previousLanguage = AppLocalization.shared.language
        let previousMemoryStore = KeychainTokenStore.useInMemoryStoreForTesting
        let previousKeys = KeychainTokenStore.inMemoryLock.withLock { KeychainTokenStore.inMemoryValues }
        KeychainTokenStore.useInMemoryStoreForTesting = true
        // Prevent the root Settings view from fetching the real account in this test process.
        let previousLogin = AuthState.shared.isLoggedIn
        AuthState.shared.isLoggedIn = false
        let suite = "SettingsBehavior-\(UUID().uuidString)"
        let fixtureDefaults = UserDefaults(suiteName: suite)
        defer {
            fixtureDefaults?.removePersistentDomain(forName: suite)
            KeychainTokenStore.inMemoryLock.withLock { KeychainTokenStore.inMemoryValues = previousKeys }
            KeychainTokenStore.useInMemoryStoreForTesting = previousMemoryStore
            AuthState.shared.isLoggedIn = previousLogin
            AppLocalization.shared.setLanguage(previousLanguage)
            NSApp.accessibilitySetValue(previousAccessibility ?? false, forAttribute: attribute)
        }
        let defaults = try #require(fixtureDefaults)
        let settings = SettingsStore(defaults: defaults)
        settings.appLanguage = .english
        AppLocalization.shared.setLanguage(.english)
        try await check(settings)
    }

    static func withWindow(_ content: some View, width: CGFloat = 980, height: CGFloat = 780,
                           check: (NSWindow, NSView) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: width, height: height))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet); sheet.close()
            }
            window.contentView = nil
            window.orderOut(nil)
            window.close()
            #expect(!window.isVisible)
            #expect(window.contentView == nil)
        }
        try await wait { !elements(in: host).isEmpty && host.bounds.width > 0 }
        host.layoutSubtreeIfNeeded()
        try await check(window, host)
    }

    static func snapshot(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 3000)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_GUL303_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private struct ReadinessTimeout: Error {}
}
