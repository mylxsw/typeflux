import AppKit
import SwiftUI
import Testing
@testable import Typeflux

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
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.toolbar = nil
            window.close()
        }
        try await SettingsBehaviorTestSupport.wait("Ask toolbar, sidebar, transcript and composer") {
            hosting.superview?.layoutSubtreeIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            guard hosting.bounds.width > 0, hosting.bounds.height > 0,
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
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
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
    }
}
