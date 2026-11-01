import AppKit
import Darwin
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
                           nativeWindow: Bool = false,
                           check: (NSWindow, NSView) async throws -> Void) async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: nativeWindow ? [.titled, .closable, .fullSizeContentView] : [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host: NSView
        if nativeWindow {
            let hosting = NSHostingView(rootView: content.frame(width: width, height: height).ignoresSafeArea())
            hosting.sizingOptions = []
            host = hosting
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
        } else {
            host = NSHostingView(rootView: content.frame(width: width, height: height))
        }
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
        if let window = host.window, window.styleMask.contains(.fullSizeContentView),
           host.bounds.size == window.frame.size,
           NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            try snapshotNativeWindow(window, name: name)
            return
        }
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

@MainActor
extension SettingsBehaviorTestSupport {
    static func captureMenu(in host: NSView, identifier: String, name: String) async throws {
        func buttons(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        try await wait { buttons(host).contains {
            $0.accessibilityIdentifier() == identifier && $0.isEnabled && $0.numberOfItems > 0
        } }
        let button = try #require(buttons(host).first { $0.accessibilityIdentifier() == identifier })
        let menu = try #require(button.menu)
        button.scrollToVisible(button.bounds)
        host.layoutSubtreeIfNeeded()
        // Page activation can replace the catalog after the incoming control is first mounted.
        try await Task.sleep(for: .milliseconds(250))
        try await wait { button.isEnabled && button.numberOfItems > 0 }
        menu.delegate?.menuNeedsUpdate?(menu)
        let previous = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        var captureError: Error?
        var captured = false
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                do {
                    try snapshotMenuWindows(host, excluding: previous, name: name)
                    captured = true
                } catch { captureError = error }
                menu.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        button.performClick(nil)
        if let captureError { throw captureError }
        try #require(captured, "The native menu must remain open for capture: \(identifier)")
    }

    static func snapshotMenuWindows(_ host: NSView, excluding previous: Set<Int>, name: String) throws {
        let window = try #require(host.window)
        let menus = NSApp.windows.filter {
            $0 !== window && $0.isVisible && !previous.contains($0.windowNumber)
                && $0.level.rawValue > NSWindow.Level.normal.rawValue
        }
        try #require(!menus.isEmpty, "A native popup window must be visible")
        // Native popup menus can extend beyond the wizard (notably the footer language menu).
        let bounds = menus.reduce(window.frame) { $0.union($1.frame) }
        let origin = bounds.origin
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        do {
            let pixels = try ownWindowImage(window)
            NSImage(cgImage: pixels, size: window.frame.size).draw(in: NSRect(
                origin: NSPoint(x: window.frame.minX - origin.x, y: window.frame.minY - origin.y),
                size: window.frame.size
            ))
            for menu in menus {
                let pixels = try ownWindowImage(menu)
                NSImage(cgImage: pixels, size: menu.frame.size).draw(in: NSRect(
                    origin: NSPoint(x: menu.frame.minX - origin.x, y: menu.frame.minY - origin.y),
                    size: menu.frame.size
                ))
            }
        } catch { image.unlockFocus(); throw error }
        image.unlockFocus()
        try write(image, name: name)
    }

    static func snapshotNativeWindow(_ window: NSWindow, overlays: [NSWindow] = [], name: String) throws {
        let pixels = try ownWindowImage(window)
        let image = NSImage(size: window.frame.size)
        image.lockFocus()
        do {
            NSImage(cgImage: pixels, size: window.frame.size).draw(in: NSRect(origin: .zero, size: window.frame.size))
            for overlay in overlays {
                let pixels = try ownWindowImage(overlay)
                NSImage(cgImage: pixels, size: overlay.frame.size).draw(in: NSRect(
                    origin: NSPoint(x: overlay.frame.minX - window.frame.minX,
                                    y: overlay.frame.minY - window.frame.minY), size: overlay.frame.size
                ))
            }
        } catch { image.unlockFocus(); throw error }
        image.unlockFocus()
        try write(image, name: name)
    }

    private static func ownWindowImage(_ window: NSWindow) throws -> CGImage {
        // Only windows owned by this test host may be captured. The runtime C API
        // preserves AppKit vibrancy without requesting global screen-recording access;
        // recent SDKs no longer expose its legacy Swift declaration.
        try #require(window.isVisible && window.windowNumber > 0 && NSApp.windows.contains { $0 === window })
        typealias Capture = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"))
        let capture = unsafeBitCast(symbol, to: Capture.self)
        return try #require(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
                                   CGWindowID(window.windowNumber),
                                   CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
    }

    private static func write(_ image: NSImage, name: String) throws {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let pixels = try #require(bitmap.cgImage)
        // Export SDR evidence at the captured pixel dimensions instead of retaining
        // the display's 16-bit working surface in every PNG.
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: pixels.width, height: pixels.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        let exported = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: exported).representation(using: .png, properties: [:]))
        #expect(png.count > 3000)
        if let path = ProcessInfo.processInfo.environment["TYPEFLUX_GUL303_SNAPSHOTS"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
