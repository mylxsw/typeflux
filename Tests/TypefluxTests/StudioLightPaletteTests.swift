import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The light palette (v4): a white content area, a grey sidebar, neutral text
/// and a single blue accent. Every dark value is pinned to its pre-v4 number.
@Suite("Studio semantic palette", .exclusiveUIState)
struct StudioLightPaletteTests {
    private struct RGBA {
        var red, green, blue, alpha: Double
    }

    private func resolve(_ color: Color, dark: Bool) -> RGBA {
        var value = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            value = RGBA(red: resolved.redComponent, green: resolved.greenComponent,
                         blue: resolved.blueComponent, alpha: resolved.alphaComponent)
        }
        return value
    }

    private func expect(_ color: Color, dark: Bool = false, hex: UInt32, alpha: Double = 1,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let value = resolve(color, dark: dark)
        let want = (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        #expect(abs(value.red - want.0) < 0.004 && abs(value.green - want.1) < 0.004
            && abs(value.blue - want.2) < 0.004 && abs(value.alpha - alpha) < 0.004,
            "got \(value), want #\(String(hex, radix: 16)) @ \(alpha)", sourceLocation: sourceLocation)
    }

    @Test func surfaceTokensUseSystemColors() {
        #expect(AskClassic.sidebar == TypefluxColor.windowBackground.color)
        for dark in [false, true] {
            for token in [TypefluxColor.windowBackground, .contentBackground, .controlBackground] {
                let value = resolve(token.color, dark: dark)
                let expected = resolve(Color(nsColor: token.nsColor), dark: dark)
                expectRGBA(value, expected)
                #expect(value.alpha == 1)
            }
        }
    }

    private func expectRGBA(_ value: RGBA, _ expected: RGBA, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(value.red - expected.red) < 0.002 && abs(value.green - expected.green) < 0.002
            && abs(value.blue - expected.blue) < 0.002 && abs(value.alpha - expected.alpha) < 0.002,
            "\(value) vs \(expected)", sourceLocation: sourceLocation)
    }

    @Test func rgbHelperDecodesHex() {
        let color = LegacyStudioPalette.rgb(0x2563EB, alpha: 0.5)
        #expect(abs(color.redComponent - 37.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 99.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 235.0 / 255) < 0.001)
        #expect(color.alphaComponent == 0.5)
    }

    @Test func backdropIsWhiteInLight() {
        let light = NSColor(AskWindowBackdrop.base(dark: false)).usingColorSpace(.sRGB)!
        #expect(light.redComponent == 1 && light.greenComponent == 1 && light.blueComponent == 1)
        #expect(AskWindowBackdrop.tintOpacity(dark: false, reduceTransparency: false) == 0.22)
        #expect(AskWindowBackdrop.tintOpacity(dark: true, reduceTransparency: false) == 0.68)
    }

    @Test func cardIsFlatOnlyInLightGlass() {
        #expect(StudioCard<EmptyView>.usesLightGlassCard(glass: true, dark: false))
        #expect(!StudioCard<EmptyView>.usesLightGlassCard(glass: true, dark: true))
        #expect(!StudioCard<EmptyView>.usesLightGlassCard(glass: false, dark: false))
    }

    @Test func primaryButtonIsSolidAccentInLightOnly() {
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: true, hovering: false) == nil)
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: false, hovering: false) == TypefluxColor.accent.color)
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: false, hovering: true) == TypefluxColor.accent.color)
    }

    @Test func sidebarSelectionIsRaisedBlockInLightOnly() {
        #expect(StudioSidebarRowBackground.usesRaisedBlock(selected: true, dark: false))
        #expect(!StudioSidebarRowBackground.usesRaisedBlock(selected: true, dark: true))
        #expect(!StudioSidebarRowBackground.usesRaisedBlock(selected: false, dark: false))
    }

    @Test func promoCardIsSeventyPercentWhite() {
        #expect(AskAccountCard.promoCardOpacity == 0.70)
    }
}
