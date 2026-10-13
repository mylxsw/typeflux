import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Studio light v4 follow-up", .serialized, .exclusiveUIState)
@MainActor
struct StudioLightFollowupTests {
    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `primary capsules are solid only in light`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let button = Button("") {}.buttonStyle(AskCapsuleButtonStyle(expands: true))
            let light = try await render(button, style: style, dark: false)
            let accent = try await render(AskTheme.accent, style: style, dark: false)
            try expectPixel(light, accent, x: 260, y: 82)
            try expectPixel(light, accent, x: 260, y: 98)
            let background = try await render(Color.black, style: style, dark: false)
            try expectPixel(light, background, x: 140, y: 115)
            let dark = try await render(button, style: style, dark: true)
            let legacy = Color.clear.frame(width: 280, height: 36)
                .background(AskTheme.accent, in: Capsule())
                .overlay(Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.18), .clear],
                                                       startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                .shadow(color: AskTheme.accent.opacity(0.4), radius: 7, y: 3)
            let expected = try await render(legacy, style: style, dark: true)
            try expectPixel(dark, expected, x: 260, y: 82)
            try expectPixel(dark, expected, x: 260, y: 98)
            try expectPixel(dark, expected, x: 140, y: 115)
            let disabled = try await render(button.disabled(true), style: style, dark: false)
            let muted = try await render(AskTheme.controlSurface, style: style, dark: false)
            try expectPixel(disabled, muted, x: 140, y: 90)
            for kind in [AskCapsuleButtonStyle.Kind.secondary, .destructive] {
                _ = try await render(Button("") {}.buttonStyle(AskCapsuleButtonStyle(kind: kind)),
                                     style: style, dark: false)
            }
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `sidebar promo uses the content card fill in light`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let backdrop = Color(red: 0.2, green: 0.4, blue: 0.6)
            let actual = try await render(AskCloudPromoCard(onSignIn: {}, onDismiss: {}), style: style,
                                          dark: false, backdrop: backdrop)
            let expected = try await render(StudioTheme.cardFill, style: style,
                                            dark: false, backdrop: backdrop)
            try expectPixel(actual, expected, x: 274, y: 90)
            // Both actions remain reachable after restyling the card.
            var signedIn = false, dismissed = false
            try await SettingsBehaviorTestSupport.withWindow(
                AskCloudPromoCard(onSignIn: { signedIn = true }, onDismiss: { dismissed = true })
            ) { _, host in
                try SettingsBehaviorTestSupport.button(L("ask.cloudPromo.signIn"), in: host).press()
                try SettingsBehaviorTestSupport.button(L("ask.cloudPromo.dismiss"), in: host).press()
                #expect(signedIn && dismissed)
            }
            _ = try await render(AskCloudPromoCard(onSignIn: {}, onDismiss: {}), style: style, dark: true)
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `unframed grid preserves card spacing and exposes the page`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            let backdrop = Color(red: 0.2, green: 0.4, blue: 0.6)
            let plain = StudioCard(showsChrome: false) { Color.clear.frame(width: 160, height: 60) }
            let framed = StudioCard { Color.clear.frame(width: 160, height: 60) }
            for dark in [false, true] {
                let actual = try await render(plain, style: style, dark: dark, backdrop: backdrop)
                let expected = try await render(backdrop, style: style, dark: dark, backdrop: backdrop)
                try expectPixel(actual, expected, x: 140, y: 90)
                try expectPixel(actual, expected, x: 37, y: 90)
            }
            let white = try await render(framed, style: style, dark: false)
            let center = try #require(white.colorAt(x: white.pixelsWide / 2,
                                                    y: white.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            #expect(center.redComponent > 0.98 && center.blueComponent > 0.98)
            // Dark vocabulary still takes the original, default card path.
            let dark = try await render(framed, style: style, dark: true)
            let explicit = try await render(StudioCard(showsChrome: true) {
                Color.clear.frame(width: 160, height: 60)
            }, style: style, dark: true)
            #expect(dark.bitmapData != nil && explicit.bitmapData != nil)
            try expectPixel(dark, explicit, x: 140, y: 90)
            let withChrome = NSHostingView(rootView: framed)
            let withoutChrome = NSHostingView(rootView: plain)
            #expect(withChrome.fittingSize == withoutChrome.fittingSize)
            #expect(withoutChrome.fittingSize == NSSize(width: 208, height: 108))
        }
    }

    @Test(arguments: [InterfaceStyle.liquidGlass, .classic])
    func `native related word buttons keep lookup actions`(style: InterfaceStyle) async throws {
        try await SettingsBehaviorTestSupport.withFixture { _ in
            for dark in [false, true] {
                var lookedUp = false
                let button = TypefluxButton("delivery speed", action: { lookedUp = true })
                    .environment(\.interfaceStyle, style).environment(\.colorScheme, dark ? .dark : .light)
                try await SettingsBehaviorTestSupport.withWindow(button) { _, host in
                    try SettingsBehaviorTestSupport.button("delivery speed", in: host).press()
                    #expect(lookedUp)
                }
            }
        }
    }

    private func render(_ view: some View, style: InterfaceStyle, dark: Bool,
                        backdrop: Color = .black) async throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 180),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: 280, height: 180)
            .environment(\.interfaceStyle, style).environment(\.colorScheme, dark ? .dark : .light)
            .background(backdrop))
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func expectPixel(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep, x: Int, y: Int) throws {
        let scale = actual.pixelsWide / 280
        let lhs = try #require(actual.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB))
        let rhs = try #require(expected.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB))
        #expect(abs(lhs.redComponent - rhs.redComponent) < 0.002)
        #expect(abs(lhs.greenComponent - rhs.greenComponent) < 0.002)
        #expect(abs(lhs.blueComponent - rhs.blueComponent) < 0.002)
    }
}
