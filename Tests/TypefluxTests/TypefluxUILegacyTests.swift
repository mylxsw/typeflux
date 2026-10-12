import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI legacy forwarding", .exclusiveUIState)
@MainActor
struct TypefluxUILegacyTests {
    @Test func `palettes forward without changing values`() {
        #expect(StudioTheme.sidebarSelection == LegacyStudioPalette.sidebarSelection)
        #expect(StudioTheme.sidebarSelectionStroke == LegacyStudioPalette.sidebarSelectionStroke)
        #expect(StudioTheme.accentText == LegacyStudioPalette.accentText)
        #expect(StudioTheme.sidePanelFill == LegacyStudioPalette.sidePanelFill)
        #expect(StudioTheme.sidePanelStroke == LegacyStudioPalette.sidePanelStroke)
        #expect(StudioTheme.cardFill == LegacyStudioPalette.cardFill)
        #expect(StudioTheme.cardStroke == LegacyStudioPalette.cardStroke)
        #expect(StudioTheme.filterChipSelectedFill == LegacyStudioPalette.filterChipSelectedFill)
        #expect(StudioTheme.placeholder == LegacyStudioPalette.placeholder)
        #expect(StudioTheme.accent == LegacyStudioPalette.accent)
        #expect(StudioTheme.accentHover == LegacyStudioPalette.accentHover)
        #expect(StudioTheme.accentSoft == LegacyStudioPalette.accentSoft)
        #expect(StudioTheme.windowBackground == LegacyStudioPalette.windowBackground)
        #expect(StudioTheme.background == LegacyStudioPalette.background)
        #expect(StudioTheme.modalSurface == LegacyStudioPalette.modalSurface)
        #expect(StudioTheme.shellSurface == LegacyStudioPalette.shellSurface)
        #expect(StudioTheme.sidebar == LegacyStudioPalette.sidebar)
        #expect(StudioTheme.surface == LegacyStudioPalette.surface)
        #expect(StudioTheme.cardSurface == LegacyStudioPalette.cardSurface)
        #expect(StudioTheme.surfaceMuted == LegacyStudioPalette.surfaceMuted)
        #expect(StudioTheme.controlSurface == LegacyStudioPalette.controlSurface)
        #expect(StudioTheme.rowSurface == LegacyStudioPalette.rowSurface)
        #expect(StudioTheme.selectionSurface == LegacyStudioPalette.selectionSurface)
        #expect(StudioTheme.selectionSurfaceRaised == LegacyStudioPalette.selectionSurfaceRaised)
        #expect(StudioTheme.localModelOptionSurface == LegacyStudioPalette.localModelOptionSurface)
        #expect(StudioTheme.segmentedTrack == LegacyStudioPalette.segmentedTrack)
        #expect(StudioTheme.iconTileSurface == LegacyStudioPalette.iconTileSurface)
        #expect(StudioTheme.modelProviderIconPlate == LegacyStudioPalette.modelProviderIconPlate)
        #expect(StudioTheme.modelProviderFallbackSymbol == LegacyStudioPalette.modelProviderFallbackSymbol)
        #expect(StudioTheme.border == LegacyStudioPalette.border)
        #expect(StudioTheme.textPrimary == LegacyStudioPalette.textPrimary)
        #expect(StudioTheme.textSecondary == LegacyStudioPalette.textSecondary)
        #expect(StudioTheme.textTertiary == LegacyStudioPalette.textTertiary)
        #expect(StudioTheme.success == LegacyStudioPalette.success)
        #expect(StudioTheme.warning == LegacyStudioPalette.warning)
        #expect(StudioTheme.danger == LegacyStudioPalette.danger)
        #expect(StudioTheme.tooltipBackground == LegacyStudioPalette.tooltipBackground)
        #expect(StudioTheme.glassTint == LegacyStudioPalette.glassTint)
        #expect(StudioTheme.glassScrim == LegacyStudioPalette.glassScrim)
        #expect(StudioTheme.glassStrokeHighlight == LegacyStudioPalette.glassStrokeHighlight)
        #expect(StudioTheme.glassStrokeShadow == LegacyStudioPalette.glassStrokeShadow)
        #expect(StudioTheme.glassInnerHighlight == LegacyStudioPalette.glassInnerHighlight)
        #expect(StudioTheme.windowHighlight == LegacyStudioPalette.windowHighlight)
        #expect(StudioTheme.shadow == LegacyStudioPalette.shadow)
        #expect(AskTheme.accent == LegacyAskPalette.accent)
        #expect(AskTheme.surface == LegacyAskPalette.surface)
        #expect(AskTheme.raisedSurface == LegacyAskPalette.raisedSurface)
        #expect(AskTheme.sidebarSurface == LegacyAskPalette.sidebarSurface)
        #expect(AskTheme.controlSurface == LegacyAskPalette.controlSurface)
        #expect(AskTheme.border == LegacyAskPalette.border)
        #expect(AskTheme.separator == LegacyAskPalette.separator)
        #expect(AskTheme.accentSoft == LegacyAskPalette.accentSoft)
        #expect(AskTheme.privateTint == LegacyAskPalette.privateTint)
        #expect(AskTheme.privateFill == LegacyAskPalette.privateFill)
        #expect(AskTheme.privateHeaderFill == LegacyAskPalette.privateHeaderFill)
        #expect(AskTheme.accentText == LegacyAskPalette.accentText)
        #expect(AskTheme.successSoft == LegacyAskPalette.successSoft)
        #expect(AskTheme.warningSoft == LegacyAskPalette.warningSoft)
        #expect(AskTheme.dangerSoft == LegacyAskPalette.dangerSoft)
        #expect(AskTheme.composerSurface == LegacyAskPalette.composerSurface)
        #expect(AskTheme.launcherSurface == LegacyAskPalette.launcherSurface)
        #expect(AskTheme.launcherGlassTint == LegacyAskPalette.launcherGlassTint)
        #expect(AskTheme.popoverSurface == LegacyAskPalette.popoverSurface)
        #expect(AskTheme.panelCard == LegacyAskPalette.panelCard)
        #expect(AskTheme.segmentTrack == LegacyAskPalette.segmentTrack)
        #expect(AskTheme.floatingBorder == LegacyAskPalette.floatingBorder)
        #expect(AskTheme.floatingGlassEdge == LegacyAskPalette.floatingGlassEdge)
        #expect(AskTheme.launcherSeparator == LegacyAskPalette.launcherSeparator)
        #expect(AskTheme.launcherSelection == LegacyAskPalette.launcherSelection)
        #expect(AskTheme.launcherSelectionEdge == LegacyAskPalette.launcherSelectionEdge)
        #expect(AskTheme.launcherKeyword == LegacyAskPalette.launcherKeyword)
        #expect(AskTheme.launcherKeywordText == LegacyAskPalette.launcherKeywordText)
        #expect(AskTheme.launcherTile == LegacyAskPalette.launcherTile)
        #expect(AskTheme.launcherTileEdge == LegacyAskPalette.launcherTileEdge)
        #expect(AskTheme.launcherChipFill == LegacyAskPalette.launcherChipFill)
        #expect(AskTheme.launcherChipEdge == LegacyAskPalette.launcherChipEdge)
        #expect(AskTheme.launcherShortcutFill == LegacyAskPalette.launcherShortcutFill)
        #expect(AskTheme.launcherShortcutEdge == LegacyAskPalette.launcherShortcutEdge)
        #expect(AskTheme.launcherMetaText == LegacyAskPalette.launcherMetaText)
        #expect(AskTheme.launcherPlaceholderText == LegacyAskPalette.launcherPlaceholderText)
        #expect(AskTheme.switchOnFill == LegacyAskPalette.switchOnFill)
        #expect(AskTheme.switchOnEdge == LegacyAskPalette.switchOnEdge)
        #expect(AskTheme.glassFill == LegacyAskPalette.glassFill)
        #expect(AskTheme.pressFill == LegacyAskPalette.pressFill)
        #expect(AskTheme.hoverFill == LegacyAskPalette.hoverFill)
        #expect(AskTheme.monoSurface == LegacyAskPalette.monoSurface)
        #expect(AskTheme.cardBorder == LegacyAskPalette.cardBorder)
        #expect(AskTheme.librarySeparator == LegacyAskPalette.librarySeparator)
        #expect(AskTheme.noteQuestionSurface == LegacyAskPalette.noteQuestionSurface)
        #expect(AskTheme.keycapSurface == LegacyAskPalette.keycapSurface)
        #expect(AskTheme.userBubble == LegacyAskPalette.userBubble)
        #expect(AskTheme.userBubbleEdge == LegacyAskPalette.userBubbleEdge)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            appearance?.performAsCurrentDrawingAppearance {
                for color in [
                    LegacyStudioPalette.sidebarSelection,
                    LegacyStudioPalette.sidebarSelectionStroke,
                    LegacyStudioPalette.accentText,
                    LegacyStudioPalette.sidePanelFill,
                    LegacyStudioPalette.sidePanelStroke,
                    LegacyStudioPalette.cardFill,
                    LegacyStudioPalette.cardStroke,
                    LegacyStudioPalette.filterChipSelectedFill,
                    LegacyStudioPalette.placeholder,
                    LegacyStudioPalette.accent,
                    LegacyStudioPalette.accentHover,
                    LegacyStudioPalette.accentSoft,
                    LegacyStudioPalette.windowBackground,
                    LegacyStudioPalette.background,
                    LegacyStudioPalette.modalSurface,
                    LegacyStudioPalette.shellSurface,
                    LegacyStudioPalette.sidebar,
                    LegacyStudioPalette.surface,
                    LegacyStudioPalette.cardSurface,
                    LegacyStudioPalette.surfaceMuted,
                    LegacyStudioPalette.controlSurface,
                    LegacyStudioPalette.rowSurface,
                    LegacyStudioPalette.selectionSurface,
                    LegacyStudioPalette.selectionSurfaceRaised,
                    LegacyStudioPalette.localModelOptionSurface,
                    LegacyStudioPalette.segmentedTrack,
                    LegacyStudioPalette.iconTileSurface,
                    LegacyStudioPalette.modelProviderIconPlate,
                    LegacyStudioPalette.modelProviderFallbackSymbol,
                    LegacyStudioPalette.border,
                    LegacyStudioPalette.textPrimary,
                    LegacyStudioPalette.textSecondary,
                    LegacyStudioPalette.textTertiary,
                    LegacyStudioPalette.success,
                    LegacyStudioPalette.warning,
                    LegacyStudioPalette.danger,
                    LegacyStudioPalette.tooltipBackground,
                    LegacyStudioPalette.glassTint,
                    LegacyStudioPalette.glassScrim,
                    LegacyStudioPalette.glassStrokeHighlight,
                    LegacyStudioPalette.glassStrokeShadow,
                    LegacyStudioPalette.glassInnerHighlight,
                    LegacyStudioPalette.windowHighlight,
                    LegacyStudioPalette.shadow,
                    LegacyAskPalette.accent,
                    LegacyAskPalette.surface,
                    LegacyAskPalette.raisedSurface,
                    LegacyAskPalette.sidebarSurface,
                    LegacyAskPalette.controlSurface,
                    LegacyAskPalette.border,
                    LegacyAskPalette.separator,
                    LegacyAskPalette.accentSoft,
                    LegacyAskPalette.privateTint,
                    LegacyAskPalette.privateFill,
                    LegacyAskPalette.privateHeaderFill,
                    LegacyAskPalette.accentText,
                    LegacyAskPalette.successSoft,
                    LegacyAskPalette.warningSoft,
                    LegacyAskPalette.dangerSoft,
                    LegacyAskPalette.composerSurface,
                    LegacyAskPalette.launcherSurface,
                    LegacyAskPalette.launcherGlassTint,
                    LegacyAskPalette.popoverSurface,
                    LegacyAskPalette.panelCard,
                    LegacyAskPalette.segmentTrack,
                    LegacyAskPalette.floatingBorder,
                    LegacyAskPalette.floatingGlassEdge,
                    LegacyAskPalette.launcherSeparator,
                    LegacyAskPalette.launcherSelection,
                    LegacyAskPalette.launcherSelectionEdge,
                    LegacyAskPalette.launcherKeyword,
                    LegacyAskPalette.launcherKeywordText,
                    LegacyAskPalette.launcherTile,
                    LegacyAskPalette.launcherTileEdge,
                    LegacyAskPalette.launcherChipFill,
                    LegacyAskPalette.launcherChipEdge,
                    LegacyAskPalette.launcherShortcutFill,
                    LegacyAskPalette.launcherShortcutEdge,
                    LegacyAskPalette.launcherMetaText,
                    LegacyAskPalette.launcherPlaceholderText,
                    LegacyAskPalette.switchOnFill,
                    LegacyAskPalette.switchOnEdge,
                    LegacyAskPalette.glassFill,
                    LegacyAskPalette.pressFill,
                    LegacyAskPalette.hoverFill,
                    LegacyAskPalette.monoSurface,
                    LegacyAskPalette.cardBorder,
                    LegacyAskPalette.librarySeparator,
                    LegacyAskPalette.noteQuestionSurface,
                    LegacyAskPalette.keycapSurface,
                    LegacyAskPalette.userBubble,
                    LegacyAskPalette.userBubbleEdge
                ] {
                    #expect(NSColor(color).usingColorSpace(.sRGB) != nil)
                }
            }
        }
    }
}
