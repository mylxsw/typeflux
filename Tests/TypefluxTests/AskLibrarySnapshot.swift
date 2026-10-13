import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Captures a titled window so native toolbar actions are included in the snapshot.
@MainActor
enum AskLibrarySnapshot {
    static func render(_ view: some View, size: NSSize, style: InterfaceStyle, dark: Bool,
                       increasedContrast: Bool = false, file: URL) async throws {
        _ = NSApplication.shared
        let content = view.environment(\.interfaceStyle, style)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.glassMaterialOverride, .opaque)
            .environment(\.typefluxAccessibilityOptions,
                         TypefluxAccessibilityOptions(reduceTransparency: true, increasedContrast: increasedContrast))
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.toolbar != nil)
        let frame = try #require(window.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: file)
    }
}
