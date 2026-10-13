import AppKit
import SwiftUI
import Testing
@testable import Typeflux
import TypefluxUI

@Suite("TypefluxUI palette compatibility", .exclusiveUIState)
@MainActor
struct TypefluxUILegacyTests {
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
