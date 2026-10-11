import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The light palette (v4): a white content area, a grey sidebar, neutral text
/// and a single blue accent. Every dark value is pinned to its pre-v4 number.
@Suite("Studio light palette")
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

    @Test func lightTextAndStatusTokens() {
        expect(StudioTheme.textPrimary, hex: 0x1D1D1F)
        expect(StudioTheme.textSecondary, hex: 0x515154)
        expect(StudioTheme.textTertiary, hex: 0x6E6E73)
        expect(StudioTheme.placeholder, hex: 0xA1A1A6)
        expect(StudioTheme.accent, hex: 0x2563EB)
        expect(StudioTheme.accentHover, hex: 0x1D4ED8)
        expect(StudioTheme.accentText, hex: 0x1D4ED8)
        expect(StudioTheme.accentSoft, hex: 0x2563EB, alpha: 0.10)
        expect(StudioTheme.border, hex: 0x0F172A, alpha: 0.08)
        expect(StudioTheme.success, hex: 0x16A34A)
        expect(StudioTheme.warning, hex: 0xD97706)
        expect(StudioTheme.danger, hex: 0xDC2626)
    }

    @Test func lightSurfaceTokens() {
        expect(StudioTheme.sidePanelFill, hex: 0xF3F4F6)
        expect(StudioTheme.sidePanelStroke, hex: 0x0F172A, alpha: 0.06)
        expect(StudioTheme.sidebarSelection, hex: 0xFFFFFF)
        expect(StudioTheme.sidebarSelectionStroke, hex: 0x0F172A, alpha: 0.08)
        expect(StudioTheme.cardFill, hex: 0xFFFFFF)
        expect(StudioTheme.cardStroke, hex: 0x0F172A, alpha: 0.09)
        expect(StudioTheme.filterChipSelectedFill, hex: 0xF3F4F6)
        expect(AskClassic.sidebar, hex: 0xF3F4F6)
        #expect(StudioTheme.Opacity.sidePanelFill == 0.94)
    }

    @Test func darkValuesAreUnchanged() {
        let checks: [(Color, Double, Double)] = [
            (StudioTheme.textPrimary, 0.935, 1), (StudioTheme.textSecondary, 0.720, 1),
            (StudioTheme.textTertiary, 0.560, 1), (StudioTheme.sidebarSelection, 1.0, 0.11),
            (StudioTheme.border, 1.0, 0.115), (StudioTheme.accentText, 0.935, 1),
            (StudioTheme.cardFill, 1.0, 0.08), (StudioTheme.sidePanelStroke, 1.0, 0),
        ]
        for (color, white, alpha) in checks {
            let value = resolve(color, dark: true)
            // The legacy tokens use AppKit's calibrated colour space, whose
            // channels change when converted to sRGB. Compare like spaces.
            let expected = resolve(Color(nsColor: NSColor(calibratedWhite: white, alpha: alpha)), dark: true)
            expectRGBA(value, expected)
        }
        let accent = resolve(StudioTheme.accent, dark: true)
        let originalAccent = Color(nsColor: NSColor(calibratedRed: 0.09, green: 0.55, blue: 1, alpha: 1))
        expectRGBA(accent, resolve(originalAccent, dark: true))
        let panel = resolve(StudioTheme.sidePanelFill, dark: true)
        #expect(abs(panel.red - 0.173) < 0.004 && abs(panel.blue - 0.204) < 0.004)
    }

    private func expectRGBA(_ value: RGBA, _ expected: RGBA, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(value.red - expected.red) < 0.002 && abs(value.green - expected.green) < 0.002
            && abs(value.blue - expected.blue) < 0.002 && abs(value.alpha - expected.alpha) < 0.002,
            "\(value) vs \(expected)", sourceLocation: sourceLocation)
    }

    @Test func rgbHelperDecodesHex() {
        let color = StudioTheme.rgb(0x2563EB, alpha: 0.5)
        #expect(abs(color.redComponent - 37.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 99.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 235.0 / 255) < 0.001)
        #expect(color.alphaComponent == 0.5)
    }

    @Test func backdropIsWhiteInLight() {
        let light = NSColor(AskWindowBackdrop.base(dark: false)).usingColorSpace(.sRGB)!
        #expect(light.redComponent == 1 && light.greenComponent == 1 && light.blueComponent == 1)
        #expect(AskWindowBackdrop.tintOpacity(dark: false, reduceTransparency: false) == 0.95)
        #expect(AskWindowBackdrop.tintOpacity(dark: true, reduceTransparency: false) == 0.78)
    }

    @Test func sidePanelIsFlatOnlyInLightGlass() {
        #expect(AskSidePanelChrome.usesFlatLightPanel(glass: true, dark: false))
        #expect(!AskSidePanelChrome.usesFlatLightPanel(glass: true, dark: true))
        #expect(!AskSidePanelChrome.usesFlatLightPanel(glass: false, dark: false))
        #expect(!AskSidePanelChrome.usesFlatLightPanel(glass: false, dark: true))
        #expect(AskSidePanelChrome.flatPanelOpacity(reduceTransparency: false) == 0.94)
        #expect(AskSidePanelChrome.flatPanelOpacity(reduceTransparency: true) == 1)
    }

    @Test func cardIsFlatOnlyInLightGlass() {
        #expect(StudioCard<EmptyView>.usesLightGlassCard(glass: true, dark: false))
        #expect(!StudioCard<EmptyView>.usesLightGlassCard(glass: true, dark: true))
        #expect(!StudioCard<EmptyView>.usesLightGlassCard(glass: false, dark: false))
    }

    @Test func primaryButtonIsSolidAccentInLightOnly() {
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: true, hovering: false) == nil)
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: false, hovering: false) == StudioTheme.accent)
        #expect(StudioButtonChromeModifier.solidPrimaryFill(dark: false, hovering: true) == StudioTheme.accentHover)
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
