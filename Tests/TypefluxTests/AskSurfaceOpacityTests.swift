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

    @Test func opaqueLauncherUsesCoolOffWhiteInLightAndDeepGreyInDark() async throws {
        let launcher = AskComposerChrome.launcher.glassBackground(.opaque)
        let cardSize = NSSize(width: 100, height: 80)
        // Native bitmap color conversion varies by the display profile; check
        // the visual brightness and tint rather than an exact sRGB token.
        // Light is a cool off-white (GUL-252): blue leads red slightly; dark is neutral.
        for (appearance, brightness, coolness) in [(NSAppearance.Name.aqua, 0.94 ... 1.0, 0.005 ... 0.03),
                                                   (.darkAqua, 0.05 ... 0.18, -0.01 ... 0.01)] {
            let bitmap = try await render(launcher, size: cardSize, appearance: appearance)
            let fill = try pixel(bitmap, x: 50, y: 40)
            #expect(brightness.contains(fill.redComponent))
            #expect(abs(fill.greenComponent - fill.redComponent) < 0.01)
            #expect(coolness.contains(fill.blueComponent - fill.redComponent))
            #expect(fill.alphaComponent > 0.999)
        }
    }

    @Test func glassFrostStaysDarkOverWhiteInBothMaterialPaths() async throws {
        for material in [AskGlassMaterial.liquidGlass, .visualEffect] {
            let glass = AskComposerChrome.launcher.glassBackground(material).background(Color.white)
            let cardSize = NSSize(width: 100, height: 80)
            let light = try await render(glass, size: cardSize, appearance: .aqua)
            let dark = try await render(glass, size: cardSize, appearance: .darkAqua)
            // This checks the SwiftUI frost against white. Window-server
            // backdrop sampling is outside the scope of bitmap captures.
            let lightFill = try pixel(light, x: 50, y: 40)
            let darkFill = try pixel(dark, x: 50, y: 40)
            #expect(lightFill.redComponent > 0.65)
            #expect(darkFill.redComponent < 0.4)
            #expect(darkFill.greenComponent < 0.4)
            #expect(darkFill.blueComponent < 0.4)
        }
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
