import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// Opt-in production-view renders for the launcher corners and adaptive frost.
/// Bitmap captures include the synthetic backdrop, but cannot show the window
/// server's behind-window blur or Liquid Glass refraction.
@Suite("Ask launcher glass snapshots", .serialized)
@MainActor
struct AskLauncherGlassVisualTests {
    @Test func `render launcher materials over bright backdrop`() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEFLUX_ASK_GLASS_SNAPSHOTS"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousLanguage = AppLocalization.shared.language
        AppLocalization.shared.setLanguage(.simplifiedChinese)
        defer { AppLocalization.shared.setLanguage(previousLanguage) }

        let size = NSSize(width: AskMetrics.launcherWidth + 36,
                          height: AskMetrics.launcherHeight(editor: AskMetrics.composerControlHeight,
                                                            banners: 0, suggestions: true) + 36)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (surface, material) in [("system", AskGlassMaterial.resolve(reduceTransparency: false)),
                                        ("fallback", .visualEffect), ("opaque", .opaque)] {
                let fixture = try AskTestFixture()
                defer { fixture.model.resetSession() }
                let view = AskLauncherView(model: fixture.model, onDismiss: {})
                    .environment(\.askGlassMaterialOverride, material)
                    .padding(18)
                    .background {
                        HStack(spacing: 0) {
                            Color.white
                            LinearGradient(colors: [.yellow, .orange, .pink], startPoint: .top, endPoint: .bottom)
                        }
                    }
                try await render(view, size: size, appearance: appearance,
                                 file: root.appendingPathComponent("launcher-\(surface)-\(name).png"))
            }
        }
    }

    private func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, file: URL) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: file)
        #expect(png.count > 4000)
    }
}
