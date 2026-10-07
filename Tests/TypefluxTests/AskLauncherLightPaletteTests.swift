import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The launcher's light palette: clearer glass, translucent washes that take on
/// the backdrop, and footer switches whose "on" state reads by shape.
@Suite("Launcher light palette")
struct AskLauncherLightPaletteTests {
    private struct RGBA: Equatable {
        var red, green, blue, alpha: Double

        func isClose(to other: RGBA, tolerance: Double = 0.005) -> Bool {
            abs(red - other.red) < tolerance && abs(green - other.green) < tolerance
                && abs(blue - other.blue) < tolerance && abs(alpha - other.alpha) < tolerance
        }
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

    /// WCAG relative luminance of an opaque sRGB colour.
    private func luminance(_ color: RGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    private func contrast(_ first: RGBA, _ second: RGBA) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func lightLauncherGlassLetsTheBackdropThrough() {
        #expect(AskGlassPlacement.floating.frost(dark: false) == 0.70)
        // Dark mode keeps its deeper frost.
        #expect(AskGlassPlacement.floating.frost(dark: true) == 0.78)
        // Menus over the transcript stay well frosted.
        #expect(AskGlassPlacement.menu.frost(dark: false) == 0.90)
    }

    @Test func frostAloneKeepsPrimaryTextReadableOverABlackWindow() {
        // The worst case: no glass tint at all, only the frost over pure black.
        let surface = resolve(AskTheme.launcherSurface, dark: false)
        let frost = AskGlassPlacement.floating.frost(dark: false)
        let backplate = RGBA(red: surface.red * frost, green: surface.green * frost,
                             blue: surface.blue * frost, alpha: 1)
        #expect(contrast(resolve(StudioTheme.textPrimary, dark: false), backplate) >= 7)
    }

    @Test func lightSurfaceIsACoolOffWhite() {
        let light = resolve(AskTheme.launcherSurface, dark: false)
        #expect(light.alpha == 1)
        #expect(light.red < 0.98 && light.blue > light.red)
        let dark = RGBA(red: 0.11, green: 0.11, blue: 0.11, alpha: 1)
        #expect(resolve(AskTheme.launcherSurface, dark: true).isClose(to: dark))
    }

    @Test func glassKeepsAFaintHairlineOnlyInLightMode() {
        let hairline = RGBA(red: 0, green: 0, blue: 0, alpha: 0.08)
        #expect(resolve(AskTheme.floatingGlassEdge, dark: false).isClose(to: hairline))
        #expect(resolve(AskTheme.floatingGlassEdge, dark: true).alpha == 0)
    }

    @Test(arguments: [
        (AskTheme.launcherSeparator, 0.07), (AskTheme.launcherSelection, 0.13), (AskTheme.launcherKeyword, 0.11),
        (AskTheme.launcherTile, 0.72), (AskTheme.launcherChipFill, 0.5), (AskTheme.launcherShortcutFill, 0.045)
    ])
    func lightWashesAreTranslucent(color: Color, alpha: Double) {
        #expect(abs(resolve(color, dark: false).alpha - alpha) < 0.005)
    }

    @Test func darkModeKeepsTheSharedTokens() {
        let pairs: [(Color, Color)] = [
            (AskTheme.launcherSeparator, AskTheme.separator),
            (AskTheme.launcherSelection, AskTheme.accentSoft),
            (AskTheme.launcherKeyword, AskTheme.accentSoft),
            (AskTheme.launcherChipEdge, AskTheme.separator),
            (AskTheme.launcherShortcutEdge, AskTheme.separator),
            (AskTheme.launcherMetaText, StudioTheme.textSecondary)
        ]
        for (launcher, shared) in pairs {
            #expect(resolve(launcher, dark: true).isClose(to: resolve(shared, dark: true)))
        }
        for clear in [AskTheme.launcherSelectionEdge, AskTheme.launcherTileEdge, AskTheme.launcherChipFill,
                      AskTheme.launcherShortcutFill] {
            #expect(resolve(clear, dark: true).alpha == 0)
        }
    }

    @Test func metaTextStepsBelowSecondaryInLightMode() {
        let meta = resolve(AskTheme.launcherMetaText, dark: false)
        #expect(meta.isClose(to: resolve(StudioTheme.textTertiary, dark: false)))
        #expect(luminance(meta) > luminance(resolve(StudioTheme.textSecondary, dark: false)))
    }

    @Test func neutralRowsSitOnARaisedTile() {
        #expect(AskLauncherSuggestions.tileFill(.neutral) == AskTheme.launcherTile)
        #expect(AskLauncherSuggestions.tileEdge(.neutral) == AskTheme.launcherTileEdge)
        for tint in [AskLauncherHome.Tint.accent, .orange, .purple, .green] {
            #expect(AskLauncherSuggestions.tileFill(tint) == AskLauncherSuggestions.tint(tint).opacity(0.14))
            #expect(AskLauncherSuggestions.tileEdge(tint) == .clear)
        }
    }

    @Test func onSwitchesSitInATintedWell() {
        #expect(AskIconChipFace.wellFill(.active, hovering: false) == AskTheme.switchOnFill)
        #expect(AskIconChipFace.wellFill(.active, hovering: true) == AskTheme.switchOnFill)
        #expect(AskIconChipFace.wellEdge(.active) == AskTheme.switchOnEdge)
        #expect(AskIconChipFace.wellFill(.neutral, hovering: false) == .clear)
        #expect(AskIconChipFace.wellFill(.neutral, hovering: true) == AskTheme.hoverFill)
        #expect(AskIconChipFace.wellFill(.unavailable, hovering: true) == .clear)
        #expect(AskIconChipFace.wellFill(.warning, hovering: false) == StudioTheme.warning.opacity(0.14))
        for style in [AskChip.Style.neutral, .warning, .unavailable] {
            #expect(AskIconChipFace.wellEdge(style) == .clear)
        }
        // Light and dark both tint the well with the accent.
        for dark in [false, true] {
            let fill = resolve(AskTheme.switchOnFill, dark: dark)
            #expect(fill.blue > fill.red + 0.3 && fill.alpha > 0.1 && fill.alpha < 0.3)
        }
    }

    @Test func onSwitchesUseTheFilledSymbolWhenThereIsOne() {
        let memoryOn = AskContextItem(kind: .memory, systemImage: "brain", style: .active, title: "Memory")
        var memoryOff = memoryOn
        memoryOff.style = .neutral
        #expect(AskIconChipFace.symbol(memoryOn) == "brain.fill")
        #expect(AskIconChipFace.symbol(memoryOff) == "brain")
        // Without a filled form the outline symbol stays, and is always drawable.
        let unknown = AskContextItem(kind: .screenshot, systemImage: "typeflux.no.such.symbol", style: .active,
                                     title: "Screenshot")
        #expect(AskIconChipFace.symbol(unknown) == "typeflux.no.such.symbol")
        let screenshot = AskContextItem(kind: .screenshot, systemImage: "camera.viewfinder", style: .active,
                                        title: "Screenshot")
        #expect(NSImage(systemSymbolName: AskIconChipFace.symbol(screenshot), accessibilityDescription: nil) != nil)
    }

    @Test func storageOnThisMacSitsInAPrivateWell() {
        #expect(AskStorageButton.wellFill(local: true, active: false) == AskTheme.privateTint.opacity(0.13))
        #expect(AskStorageButton.wellFill(local: true, active: true) == AskTheme.privateTint.opacity(0.13))
        #expect(AskStorageButton.wellFill(local: false, active: true) == AskTheme.hoverFill)
        #expect(AskStorageButton.wellFill(local: false, active: false) == .clear)
    }
}
