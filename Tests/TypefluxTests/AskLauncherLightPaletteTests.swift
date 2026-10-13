import AppKit
import SwiftUI
import Testing
@testable import Typeflux

/// The launcher's light palette: stable light glass, translucent washes that take on
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

    @Test func legacyFloatingCardsAndMenusKeepTheirReadabilityFrost() {
        #expect(AskGlassPlacement.floating.frost(dark: false) == 0.92)
        // Dark mode keeps its original frost.
        #expect(AskGlassPlacement.floating.frost(dark: true) == 0.78)
        // Menus over the transcript stay well frosted.
        #expect(AskGlassPlacement.menu.frost(dark: false) == 0.92)
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
        (AskTheme.launcherSeparator, 0.08), (AskTheme.launcherSelection, 0.10), (AskTheme.launcherKeyword, 0.06),
        (AskTheme.launcherTile, 0.24), (AskTheme.launcherChipFill, 0.08)
    ])
    func lightWashesAreTranslucent(color: Color, alpha: Double) {
        #expect(abs(resolve(color, dark: false).alpha - alpha) < 0.005)
    }

    @Test func darkModeKeepsTheSharedTokens() {
        let pairs: [(Color, Color)] = [
            (AskTheme.launcherShortcutEdge, AskTheme.separator)
        ]
        for (launcher, shared) in pairs {
            #expect(resolve(launcher, dark: true).isClose(to: resolve(shared, dark: true)))
        }
        for clear in [AskTheme.launcherSelectionEdge, AskTheme.launcherTileEdge, AskTheme.launcherChipFill,
                      AskTheme.launcherShortcutFill] {
            #expect(resolve(clear, dark: true).alpha == 0)
        }
    }

    @Test func darkLauncherSelectionAndKeywordsStayNeutralAndReadable() {
        for color in [AskTheme.launcherSelection, AskTheme.launcherKeyword, AskTheme.launcherKeywordText] {
            let value = resolve(color, dark: true)
            #expect(abs(value.red - value.green) < 0.005)
            #expect(abs(value.red - value.blue) < 0.005)
        }
        #expect(contrast(resolve(StudioTheme.textPrimary, dark: true),
                         resolve(AskTheme.launcherSelection, dark: true)) >= 7)
        #expect(contrast(resolve(AskTheme.launcherMetaText, dark: true),
                         resolve(AskTheme.launcherSelection, dark: true)) >= 4.5)
        #expect(contrast(resolve(AskTheme.launcherPlaceholderText, dark: true),
                         resolve(AskTheme.launcherSurface, dark: true)) >= 4.5)
        let text = resolve(AskTheme.launcherKeywordText, dark: true)
        let keyword = resolve(AskTheme.launcherKeyword, dark: true)
        // The keyword's translucent fill cannot exceed its opaque source luminance
        // over the launcher's dark surface.
        #expect(contrast(text, keyword) >= 4.5)
    }

    @Test func lightGlassAndSelectionStayNeutralWithReadableTitles() {
        let glass = resolve(AskTheme.launcherGlassTint, dark: false)
        #expect(glass.red > 0.85 && glass.red < 0.92)
        #expect(glass.red == glass.green && glass.green == glass.blue)
        // The reference's selected row is near #B4B4B4. Use a slightly darker
        // reading surface so captions remain legible as desktop colors shift.
        let selected = RGBA(red: 0.70, green: 0.70, blue: 0.70, alpha: 1)
        #expect(contrast(resolve(StudioTheme.textPrimary, dark: false), selected) >= 7)
        #expect(resolve(AskTheme.launcherSelectionEdge, dark: false).alpha == 0)
        let keywordText = resolve(AskTheme.launcherKeywordText, dark: false)
        #expect(keywordText.red == keywordText.green && keywordText.green == keywordText.blue)
        #expect(contrast(keywordText, selected) >= 4.5)
        #expect(contrast(resolve(AskTheme.launcherMetaText, dark: false), selected) >= 4.5)
        #expect(resolve(AskTheme.launcherGlassTint, dark: true)
            .isClose(to: RGBA(red: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)))
    }

    @Test func metadataRemainsSecondaryToTitlesInLightMode() {
        let meta = resolve(AskTheme.launcherMetaText, dark: false)
        #expect(meta.isClose(to: RGBA(red: 0.27, green: 0.27, blue: 0.27, alpha: 1)))
        #expect(luminance(meta) > luminance(resolve(StudioTheme.textPrimary, dark: false)))
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
        for style in [AskContextItem.Style.neutral, .warning, .unavailable] {
            #expect(AskIconChipFace.wellEdge(style) == .clear)
        }
        // Light and dark both tint the well with the accent.
        for dark in [false, true] {
            let fill = resolve(AskTheme.switchOnFill, dark: dark)
            #expect(fill.blue > fill.red + 0.3 && fill.alpha >= 0.099 && fill.alpha < 0.3)
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
        #expect(AskStorageButton.wellFill(local: true, active: false) == AskTheme.privateFill)
        #expect(AskStorageButton.wellFill(local: true, active: true) == AskTheme.privateFill)
        #expect(AskStorageButton.wellFill(local: false, active: true) == AskTheme.hoverFill)
        #expect(AskStorageButton.wellFill(local: false, active: false) == .clear)
    }
}
