import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Run callers with `.exclusiveUIState`. Bitmap rendering cannot capture the
/// window server's glass compositor, so navigation uses its opaque fallback.
@MainActor
enum TypefluxUISnapshot {
    static func renderMatrix(_ view: some View, size: NSSize, directory: URL, name: String,
                             increasedContrast: Bool = false) async throws {
        for style in InterfaceStyle.allCases {
            for dark in [false, true] {
                try await render(view, size: size, style: style, dark: dark, increasedContrast: increasedContrast,
                                 file: directory
                                     .appendingPathComponent(
                                         "\(name)-\(style.rawValue)-\(dark ? "dark" : "light").png"
                                     ))
            }
        }
    }

    static func render(_ view: some View, size: NSSize, style: InterfaceStyle, dark: Bool,
                       increasedContrast: Bool = false, file: URL) async throws {
        _ = NSApplication.shared
        let content = view.environment(\.interfaceStyle, style)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
            .environment(\.askGlassMaterialOverride, .opaque)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = hosting.appearance
        window.contentView = hosting
        defer { TypefluxNavigationTestSupport.closeWindow(window) }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1000)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: file)
    }
}
