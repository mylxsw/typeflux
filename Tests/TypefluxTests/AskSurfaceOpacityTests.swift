import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask launcher surfaces", .serialized)
@MainActor
struct AskSurfaceOpacityTests {
    private let size = NSSize(width: AskMetrics.launcherWidth,
                              height: AskMetrics.launcherHeight(editor: 32, banners: 0))

    /// The glass itself is composited by the window server against what lies
    /// behind the panel, so an in-process snapshot cannot show the backdrop
    /// through it. What can be checked here is that every material keeps the
    /// panel's exterior transparent for its rounded corners and recording halo.
    @Test func everyLauncherMaterialKeepsATransparentExterior() async throws {
        let fixture = try AskTestFixture()
        for material in [AskGlassMaterial.liquidGlass, .visualEffect, .opaque] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                    .environment(\.askGlassMaterialOverride, material)
                let red = try await render(launcher.background(Color.red), size: size, appearance: appearance)
                let blue = try await render(launcher.background(Color.blue), size: size, appearance: appearance)
                let outsideRed = try pixel(red, x: 0, y: 0)
                let outsideBlue = try pixel(blue, x: 0, y: 0)
                #expect(abs(outsideRed.redComponent - outsideBlue.redComponent) > 0.5)
                let bare = try await render(launcher, size: size, appearance: appearance)
                #expect(try pixel(bare, x: 0, y: 0).alphaComponent < 0.01)
            }
        }
        fixture.model.resetSession()
    }

    @Test func reduceTransparencyKeepsTheLauncherCardOpaque() async throws {
        let fixture = try AskTestFixture()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let launcher = AskLauncherView(model: fixture.model, onDismiss: {})
                .environment(\.askGlassMaterialOverride, .opaque)
            let red = try await render(launcher.background(Color.red), size: size, appearance: appearance)
            let blue = try await render(launcher.background(Color.blue), size: size, appearance: appearance)
            try expectSamePixel(red, blue, x: 340, y: 50)
            let bare = try await render(launcher, size: size, appearance: appearance)
            #expect(try pixel(bare, x: 340, y: 50).alphaComponent > 0.999)
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
