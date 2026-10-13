import AppKit
import SwiftUI
import Testing
@testable import Typeflux
@testable import TypefluxUI

/// Ask-only readiness checks. Shared library and input-action helpers keep their behavior.
@MainActor
enum AskWorkspaceSnapshot {
    static func render(model: AskConversationModel, defaults: UserDefaults, size: NSSize,
                       style: InterfaceStyle, dark: Bool, showsUsage: Bool = false,
                       accessibility: TypefluxAccessibilityOptions = .init(), file: URL?) async throws {
        TypefluxTestApplicationEnvironment.prepare()
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil },
                             loadStoredUserProfile: { nil }, clearStoredSession: {})
        let view = AskConversationView(model: model, showsUsage: showsUsage, auth: auth)
            .defaultAppStorage(defaults)
            .environment(\.interfaceStyle, style)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.typefluxAccessibilityOptions, accessibility)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: accessibility.increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        window.contentView = hosting
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await SettingsBehaviorTestSupport.wait("Ask snapshot key window") {
            if NSApp.isActive, !window.isKeyWindow { window.makeKey() }
            return NSApp.isActive && window.isKeyWindow
        }
        try await SettingsBehaviorTestSupport.wait("Ask toolbar, sidebar, transcript and composer") {
            hosting.superview?.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            guard hosting.bounds.width > 0, hosting.bounds.height > 0,
                  window.title == (model.selected?.title ?? L("ask.new")),
                  window.toolbar?.items.contains(where: { $0 is NSSearchToolbarItem }) == true,
                  let editor = SettingsBehaviorTestSupport.nativeViews(in: hosting)
                    .compactMap({ $0 as? AskComposerTextView.Editor }).first,
                  editor.visibleRect.width > 0, editor.visibleRect.height > 0 else { return false }
            let elements = SettingsBehaviorTestSupport.elements(in: hosting)
            let ids = Set(elements.compactMap { $0.value("accessibilityIdentifier") as? String })
            let layout = AskWorkspaceLayout(size: size, sidebarCollapsed: false, showsUsage: showsUsage)
            if layout.usageOverlay { return ids.contains("ask.workspace.drawer.close") }
            return (!layout.sidebarInline || ids.contains("ask.workspace.history"))
                && (model.selected == nil || ids.contains("ask.workspace.transcript"))
        }
        #expect(window.title == (model.selected?.title ?? L("ask.new")))
        guard let file else { return }
        // A frame-view bitmap can include only the title bar while omitting hosted layers.
        // Capture the composited window, after readiness, as Settings/Notes acceptance does.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try #require(NSApp.isActive && window.isKeyWindow, "Capture the actual active Ask window")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "Window capture failed; check Screen Recording access")
        let data = try Data(contentsOf: file)
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide >= Int(size.width))
        #expect(image.pixelsHigh >= Int(size.height))
        #expect(data.count > 10_000, "The full workspace must contain more than title-bar chrome")
        try assertProminentNewFill(in: image, window: window)
    }

    private static func assertProminentNewFill(in image: NSBitmapImageRep, window: NSWindow) throws {
        let item = try #require(window.toolbar?.items.first {
            $0.itemIdentifier.rawValue.contains("ask.workspace.new")
        })
        let root = try #require(item.view)
        let button = try #require(SettingsBehaviorTestSupport.nativeViews(in: root)
            .compactMap { $0 as? TypefluxProminentToolbarButton.ToolbarView }.first?.button)
        // Open drawers intentionally disable the background toolbar.
        guard button.isEnabled else { return }
        var accent: NSColor?
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = TypefluxColor.accent.nsColor.usingColorSpace(.sRGB)
        }
        let target = try #require(accent)
        let targetChroma = max(target.redComponent, target.greenComponent, target.blueComponent)
            - min(target.redComponent, target.greenComponent, target.blueComponent)
        // A user-selected graphite accent has no chroma; native style assertions cover that preference.
        guard targetChroma > 0.2 else { return }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: 2, dy: 2)
        let scaleX = CGFloat(image.pixelsWide) / window.frame.width
        let scaleY = CGFloat(image.pixelsHigh) / window.frame.height
        let left = max(0, Int((frame.minX - window.frame.minX) * scaleX))
        let right = min(image.pixelsWide, Int((frame.maxX - window.frame.minX) * scaleX))
        let top = max(0, Int((window.frame.maxY - frame.maxY) * scaleY))
        let bottom = min(image.pixelsHigh, Int((window.frame.maxY - frame.minY) * scaleY))
        try #require(left < right && top < bottom, "New toolbar button must be in the captured window")
        var samples = 0
        var accented = 0
        for y in stride(from: top, to: bottom, by: max(1, Int(scaleY))) {
            for x in stride(from: left, to: right, by: max(1, Int(scaleX))) {
                guard let pixel = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                samples += 1
                let chroma = max(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                    - min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                let distance = abs(pixel.redComponent - target.redComponent)
                    + abs(pixel.greenComponent - target.greenComponent) + abs(pixel.blueComponent - target.blueComponent)
                if chroma > targetChroma * 0.35, distance < 0.7 { accented += 1 }
            }
        }
        #expect(samples > 0 && accented * 3 > samples,
                "The active New button needs an accent fill, beyond a colored icon or plain grey bezel")
    }
}
