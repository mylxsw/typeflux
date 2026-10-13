import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI palette compatibility", .exclusiveUIState)
@MainActor
struct TypefluxUILegacyTests {
    @Test func studioNamesUseSemanticTokensAndRemainingNamesKeepFrozenValues() {
        #expect(StudioTheme.sidebarSelection == LegacyStudioPalette.sidebarSelection)
        #expect(StudioTheme.sidebarSelectionStroke == LegacyStudioPalette.sidebarSelectionStroke)
        #expect(StudioTheme.accentText == TypefluxColor.accent.color)
        #expect(StudioTheme.sidePanelFill == LegacyStudioPalette.sidePanelFill)
        #expect(StudioTheme.sidePanelStroke == LegacyStudioPalette.sidePanelStroke)
        #expect(StudioTheme.cardFill == LegacyStudioPalette.cardFill)
        #expect(StudioTheme.cardStroke == LegacyStudioPalette.cardStroke)
        #expect(StudioTheme.filterChipSelectedFill == LegacyStudioPalette.filterChipSelectedFill)
        #expect(StudioTheme.placeholder == LegacyStudioPalette.placeholder)
        #expect(StudioTheme.accent == TypefluxColor.accent.color)
        #expect(StudioTheme.accentHover == LegacyStudioPalette.accentHover)
        #expect(StudioTheme.accentSoft == TypefluxColor.accent.color.opacity(0.12))
        #expect(StudioTheme.windowBackground == LegacyStudioPalette.windowBackground)
        #expect(StudioTheme.background == LegacyStudioPalette.background)
        #expect(StudioTheme.modalSurface == LegacyStudioPalette.modalSurface)
        #expect(StudioTheme.shellSurface == LegacyStudioPalette.shellSurface)
        #expect(StudioTheme.sidebar == LegacyStudioPalette.sidebar)
        #expect(StudioTheme.surface == TypefluxColor.controlBackground.color)
        #expect(StudioTheme.cardSurface == LegacyStudioPalette.cardSurface)
        #expect(StudioTheme.surfaceMuted == LegacyStudioPalette.surfaceMuted)
        #expect(StudioTheme.controlSurface == TypefluxColor.controlBackground.color)
        #expect(StudioTheme.rowSurface == LegacyStudioPalette.rowSurface)
        #expect(StudioTheme.selectionSurface == LegacyStudioPalette.selectionSurface)
        #expect(StudioTheme.selectionSurfaceRaised == LegacyStudioPalette.selectionSurfaceRaised)
        #expect(StudioTheme.localModelOptionSurface == LegacyStudioPalette.localModelOptionSurface)
        #expect(StudioTheme.segmentedTrack == LegacyStudioPalette.segmentedTrack)
        #expect(StudioTheme.iconTileSurface == LegacyStudioPalette.iconTileSurface)
        #expect(StudioTheme.modelProviderIconPlate == LegacyStudioPalette.modelProviderIconPlate)
        #expect(StudioTheme.modelProviderFallbackSymbol == LegacyStudioPalette.modelProviderFallbackSymbol)
        #expect(StudioTheme.border == TypefluxColor.separator.color)
        #expect(StudioTheme.textPrimary == TypefluxColor.label.color)
        #expect(StudioTheme.textSecondary == TypefluxColor.secondaryLabel.color)
        #expect(StudioTheme.textTertiary == TypefluxColor.tertiaryLabel.color)
        #expect(StudioTheme.success == TypefluxColor.success.color)
        #expect(StudioTheme.warning == TypefluxColor.warning.color)
        #expect(StudioTheme.danger == TypefluxColor.danger.color)
        #expect(StudioTheme.tooltipBackground == LegacyStudioPalette.tooltipBackground)
        #expect(StudioTheme.glassTint == LegacyStudioPalette.glassTint)
        #expect(StudioTheme.glassScrim == LegacyStudioPalette.glassScrim)
        #expect(StudioTheme.glassStrokeHighlight == LegacyStudioPalette.glassStrokeHighlight)
        #expect(StudioTheme.glassStrokeShadow == LegacyStudioPalette.glassStrokeShadow)
        #expect(StudioTheme.glassInnerHighlight == LegacyStudioPalette.glassInnerHighlight)
        #expect(StudioTheme.windowHighlight == LegacyStudioPalette.windowHighlight)
        #expect(StudioTheme.shadow == LegacyStudioPalette.shadow)
    }

    @Test func askNamesUseSemanticTokensAndLauncherNamesKeepFrozenValues() {
        #expect(AskTheme.accent == TypefluxColor.accent.color)
        #expect(AskTheme.surface == TypefluxColor.controlBackground.color)
        #expect(AskTheme.raisedSurface == TypefluxColor.windowBackground.color)
        #expect(AskTheme.sidebarSurface == TypefluxColor.windowBackground.color)
        #expect(AskTheme.controlSurface == TypefluxColor.controlBackground.color)
        #expect(AskTheme.border == TypefluxColor.separator.color)
        #expect(AskTheme.separator == TypefluxColor.separator.color)
        #expect(AskTheme.accentSoft == TypefluxColor.accent.color.opacity(0.12))
        #expect(AskTheme.privateTint == Color(nsColor: .systemPurple))
        #expect(AskTheme.privateFill == LegacyAskPalette.privateFill)
        #expect(AskTheme.privateHeaderFill == LegacyAskPalette.privateHeaderFill)
        #expect(AskTheme.accentText == TypefluxColor.accent.color)
        #expect(AskTheme.successSoft == TypefluxColor.success.color.opacity(0.12))
        #expect(AskTheme.warningSoft == TypefluxColor.warning.color.opacity(0.12))
        #expect(AskTheme.dangerSoft == TypefluxColor.danger.color.opacity(0.12))
        #expect(AskTheme.composerSurface == TypefluxColor.controlBackground.color)
        #expect(AskTheme.launcherSurface == LegacyAskPalette.launcherSurface)
        #expect(AskTheme.launcherGlassTint == LegacyAskPalette.launcherGlassTint)
        #expect(AskTheme.popoverSurface == TypefluxColor.windowBackground.color)
        #expect(AskTheme.panelCard == TypefluxColor.controlBackground.color)
        #expect(AskTheme.segmentTrack == TypefluxColor.controlBackground.color)
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
        #expect(AskTheme.pressFill == TypefluxColor.label.color.opacity(0.1))
        #expect(AskTheme.hoverFill == TypefluxColor.label.color.opacity(0.06))
        #expect(AskTheme.monoSurface == TypefluxColor.controlBackground.color)
        #expect(AskTheme.cardBorder == TypefluxColor.separator.color)
        #expect(AskTheme.librarySeparator == TypefluxColor.separator.color)
        #expect(AskTheme.noteQuestionSurface == LegacyAskPalette.noteQuestionSurface)
        #expect(AskTheme.keycapSurface == LegacyAskPalette.keycapSurface)
        #expect(AskTheme.userBubble == TypefluxColor.controlBackground.color)
        #expect(AskTheme.userBubbleEdge == TypefluxColor.separator.color)
    }

    @Test func frozenPalettesResolveInBothAppearances() {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            appearance?.performAsCurrentDrawingAppearance {
                for color in Self.frozenStudioColors + Self.frozenAskColors {
                    #expect(NSColor(color).usingColorSpace(.sRGB) != nil)
                }
            }
        }
    }

    private static let frozenStudioColors: [Color] = [
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
        LegacyStudioPalette.shadow
    ]

    private static let frozenAskColors: [Color] = [
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
    ]
}
