import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask opaque surfaces", .serialized)
@MainActor
struct AskSurfaceOpacityTests {
    @Test func desktopColorsDoNotBleedThroughCardsOrWorkspace() async throws {
        let fixture = try AskTestFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
            let red = try await render(launcher.background(Color.red), size: NSSize(width: 640, height: 110), appearance: appearance)
            let blue = try await render(launcher.background(Color.blue), size: NSSize(width: 640, height: 110), appearance: appearance)
            try expectSamePixel(red, blue, x: 320, y: 50)
            // The native panel still needs a transparent exterior for its rounded
            // corners and glow. This also proves the backdrops reached the render.
            let outsideRed = try pixel(red, x: 0, y: 0)
            let outsideBlue = try pixel(blue, x: 0, y: 0)
            #expect(abs(outsideRed.redComponent - outsideBlue.redComponent) > 0.5)

            let workspace = AskConversationView(model: fixture.model)
            let workspaceRed = try await render(workspace.background(Color.red), size: NSSize(width: 1100, height: 740), appearance: appearance)
            let workspaceBlue = try await render(workspace.background(Color.blue), size: NSSize(width: 1100, height: 740), appearance: appearance)
            for (x, y) in [(100, 350), (500, 350), (500, 690)] {
                try expectSamePixel(workspaceRed, workspaceBlue, x: x, y: y)
            }
            let bare = try await render(launcher, size: NSSize(width: 640, height: 110), appearance: appearance)
            #expect(try pixel(bare, x: 320, y: 50).alphaComponent > 0.999)
            #expect(try pixel(bare, x: 0, y: 0).alphaComponent < 0.01)
        }
        fixture.model.resetSession()
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        // Normalize sample coordinates for Retina and non-Retina test hosts.
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        return try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
    }

    private func expectSamePixel(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, x: Int, y: Int) throws {
        let a = try pixel(lhs, x: x, y: y), b = try pixel(rhs, x: x, y: y)
        #expect(abs(a.redComponent - b.redComponent) < 0.01)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.01)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.01)
    }

    private func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting; window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }
}
