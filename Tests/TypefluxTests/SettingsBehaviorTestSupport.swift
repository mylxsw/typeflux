import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
enum SettingsBehaviorTestSupport {
    struct Element {
        let object: NSObject
        var window: NSWindow?

        func value(_ key: String) -> Any? {
            if object.responds(to: NSSelectorFromString(key)) { return object.value(forKey: key) }
            // Native outline rows expose the informal AppKit accessibility protocol.
            let attributes = ["accessibilityRole": "AXRole", "accessibilityLabel": "AXDescription",
                              "accessibilityValue": "AXValue", "accessibilityFrame": "AXFrame",
                              "accessibilityChildren": "AXChildren", "accessibilityRows": "AXRows",
                              "accessibilityIdentifier": "AXIdentifier"]
            guard let attribute = attributes[key] else { return nil }
            return object.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
        }

        var label: String {
            if let label = value("accessibilityLabel") as? String, !label.isEmpty { return label }
            return object.accessibilityAttributeValue(.title) as? String ?? ""
        }

        var text: String {
            value("accessibilityValue") as? String ?? label
        }

        var role: String {
            (value("accessibilityRole") as? NSAccessibility.Role)?.rawValue
                ?? value("accessibilityRole") as? String ?? ""
        }

        var frame: NSRect {
            if let frame = value("accessibilityFrame") as? NSValue { return frame.rectValue }
            guard let position = object.accessibilityAttributeValue(.position) as? NSValue,
                  let size = object.accessibilityAttributeValue(.size) as? NSValue else { return .zero }
            return NSRect(origin: position.pointValue, size: size.sizeValue)
        }
    }

    static func elements(in root: Any) -> [Element] {
        let window = (root as? NSWindow) ?? (root as? NSView)?.window
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: Any) -> [Element] {
            guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = Element(object: object, window: window)
            let children = (element.value("accessibilityChildren") as? [Any] ?? [])
                + (element.value("accessibilityRows") as? [Any] ?? [])
            return [element] + children.flatMap(walk)
        }
        return walk(root)
    }

    static func button(_ title: String, in root: Any) throws -> Element {
        let roles = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue,
                     NSAccessibility.Role.link.rawValue]
        return try #require(elements(in: root).first { roles.contains($0.role) && $0.label == title },
                     "Missing rendered button: \(title)")
    }

    static func contains(_ text: String, in root: Any) -> Bool {
        elements(in: root).contains { $0.text == text || $0.label == text }
    }

    static func wait(_ description: String = "The expected UI state", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                Issue.record("\(description) did not become ready within three seconds")
                throw ReadinessTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func withFixture(_ check: (SettingsStore) async throws -> Void) async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let previousLanguage = AppLocalization.shared.language
        let previousMemoryStore = KeychainTokenStore.useInMemoryStoreForTesting
        let previousKeys = KeychainTokenStore.inMemoryLock.withLock { KeychainTokenStore.inMemoryValues }
        KeychainTokenStore.useInMemoryStoreForTesting = true
        // Prevent the root Settings view from fetching the real account in this test process.
        let previousLogin = AuthState.shared.isLoggedIn
        AuthState.shared.isLoggedIn = false
        // VocabularyStore still uses standard defaults; isolate it along with the settings suite.
        let vocabularyKeys = ["vocabulary.entries", "vocabulary.entries.\(CloudDataLocalScope.key)"]
        let previousVocabulary = vocabularyKeys.map { UserDefaults.standard.object(forKey: $0) }
        vocabularyKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let suite = "SettingsBehavior-\(UUID().uuidString)"
        let fixtureDefaults = UserDefaults(suiteName: suite)
        defer {
            fixtureDefaults?.removePersistentDomain(forName: suite)
            for (key, value) in zip(vocabularyKeys, previousVocabulary) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            KeychainTokenStore.inMemoryLock.withLock { KeychainTokenStore.inMemoryValues = previousKeys }
            KeychainTokenStore.useInMemoryStoreForTesting = previousMemoryStore
            AuthState.shared.isLoggedIn = previousLogin
            AppLocalization.shared.setLanguage(previousLanguage)
        }
        let defaults = try #require(fixtureDefaults)
        let settings = SettingsStore(defaults: defaults)
        settings.appLanguage = .english
        AppLocalization.shared.setLanguage(.english)
        try await check(settings)
    }

    static func withWindow(_ content: some View, width: CGFloat = 980, height: CGFloat = 780,
                           check: (NSWindow, NSView) async throws -> Void) async throws {
        TypefluxTestApplicationEnvironment.prepare()
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
