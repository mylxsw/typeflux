import AppKit
import SwiftUI
import Testing
import TypefluxUI

@Suite("TypefluxUI token resolution", .exclusiveUIState)
@MainActor
struct TypefluxUITokenTests {
    @Test func sidebarBackingStaysDistinctFromTheReadingSurface() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var sidebar: NSColor?
            var reading: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                // This token backs Liquid Glass's opaque sidebar, rather than Classic's window surface.
                sidebar = NSColor(cgColor: TypefluxColor.sidebarBackground.nsColor.cgColor)?.usingColorSpace(.sRGB)
                reading = NSColor(cgColor: TypefluxColor.contentBackground.nsColor.cgColor)?.usingColorSpace(.sRGB)
            }
            let left = try #require(sidebar)
            let right = try #require(reading)
            #expect(left.alphaComponent == 1)
            #expect(abs(left.redComponent - right.redComponent) + abs(left.greenComponent - right.greenComponent)
                + abs(left.blueComponent - right.blueComponent) > 0.01)
        }
    }

    @Test func `every style appearance accessibility and capability combination`() {
        for style in InterfaceStyle.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for reduced in [false, true] {
                    for contrasted in [false, true] {
                        for supported in [false, true] {
                            let tokens = TypefluxTokens(style: style, colorScheme: scheme,
                                                        reduceTransparency: reduced, increasedContrast: contrasted,
                                                        supportsLiquidGlass: supported)
                            let expected: GlassMaterial = style == .classic || reduced || contrasted
                                ? .opaque : supported ? .liquidGlass : .visualEffect
                            #expect(tokens.material == expected)
                            #expect(tokens.material.drawsOwnEdge == (expected != .opaque))
                            checkMetrics(tokens)
                            for color in TypefluxColor.allCases {
                                #expect(tokens.color(color).usingColorSpace(.sRGB) != nil)
                            }
                            let content = TypefluxTokens(style: style, colorScheme: scheme,
                                                         reduceTransparency: reduced, increasedContrast: contrasted,
                                                         layer: .content,
                                                         supportsLiquidGlass: supported)
                            #expect(content.material == .opaque)
                        }
                    }
                }
            }
        }
    }

    private func checkMetrics(_ tokens: TypefluxTokens) {
        // Independent expected tables from UI System §4, ordered like the public cases.
        let classicRadii: [CGFloat] = [10, 0, 5, 6, 0, 6, 5.5, 7, 5.5, 5, 6, 3.5, 8, 6, 4, 10, 10, 12, 12, 14, 8, 10]
        let glassRadii: [CGFloat] = [26, 18, 10, 6, 18, 18, 8, 17, 8, 8, 14, 5, 14, 14, 8, 18, 22, 28, 24, 18, 10, 14]
        let classicHeights: [CGFloat] = [52, 28, 28, 24, 24, 22, 28, 22, 22, 22, 18, 14, 36, 24, 22, 52, 34, 52]
        let glassHeights: [CGFloat] = [52, 32, 28, 36, 36, 26, 34, 26, 26, 28, 22, 16, 40, 28, 24, 56, 40, 56]
        let radii = tokens.style == .classic ? classicRadii : glassRadii
        let heights = tokens.style == .classic ? classicHeights : glassHeights
        #expect(TypefluxRadius.allCases.count == radii.count)
        #expect(TypefluxControlHeight.allCases.count == heights.count)
        for (token, expected) in zip(TypefluxRadius.allCases, radii) {
            #expect(tokens.radius(token) == expected)
        }
        for (token, expected) in zip(TypefluxControlHeight.allCases, heights) {
            #expect(tokens.height(token) == expected)
        }
        let widths: [CGFloat] = tokens.style == .classic ? [28, 200, 32, 14, 640] : [36, 240, 38, 16, 680]
        #expect(TypefluxControlWidth.allCases.count == widths.count)
        for (token, expected) in zip(TypefluxControlWidth.allCases, widths) {
            #expect(tokens.width(token) == expected)
        }
        #expect(tokens.spacing(.sidebarInset) == (tokens.style == .classic ? 0 : 8))
        #expect(tokens.spacing(.sidebarRowInset) == 8)
        for (token, value) in zip([TypefluxSpacing.compact, .small, .regular, .large, .section],
                                  [CGFloat(4), 8, 12, 16, 24]) {
            #expect(tokens.spacing(token) == value)
        }
        #expect(tokens.radius(.sidebar) == tokens.radius(.window) - tokens.spacing(.sidebarInset) || tokens
            .style == .classic)
    }

    @Test func `semantic roles and text styles use system APIs`() {
        let system: [NSColor] = [.labelColor, .secondaryLabelColor, .tertiaryLabelColor, .quaternaryLabelColor,
                                 .windowBackgroundColor, .textBackgroundColor, .controlBackgroundColor, .separatorColor,
                                 .controlAccentColor, .selectedContentBackgroundColor, .systemGreen, .systemOrange,
                                 .systemRed]
        for (token, expected) in zip(TypefluxColor.allCases.filter { $0 != .sidebarBackground }, system) {
            #expect(token.nsColor == expected)
            #expect(token.color == Color(nsColor: expected))
        }
        let styles: [Font.TextStyle] = [
            .largeTitle,
            .title,
            .title2,
            .title3,
            .headline,
            .body,
            .callout,
            .subheadline,
            .footnote
        ]
        for (token, expected) in zip(TypefluxTextStyle.allCases, styles) {
            #expect(token.textStyle == expected)
            #expect(token.font == Font.system(expected))
        }
        let tokens = TypefluxTokens(style: .liquidGlass, colorScheme: .light)
        #expect(tokens.material == (GlassMaterial.systemSupportsLiquidGlass ? .liquidGlass : .visualEffect))
    }

    @Test func `shared environment keeps defaults and overrides`() {
        var values = EnvironmentValues()
        #expect(values.interfaceStyle == .liquidGlass)
        #expect(values.liquidGlassIntensity == LiquidGlassIntensity())
        #expect(values.glassMaterialOverride == nil)
        values.interfaceStyle = .classic
        values.liquidGlassIntensity = LiquidGlassIntensity(0.2)
        values.glassMaterialOverride = .opaque
        #expect(values.interfaceStyle == .classic)
        #expect(values.liquidGlassIntensity.value == 0.2)
        #expect(values.glassMaterialOverride == .opaque)
    }
}
