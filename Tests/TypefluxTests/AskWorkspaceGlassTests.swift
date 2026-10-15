import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask workspace glass")
struct AskWorkspaceGlassTests {
    @Test(arguments: [false, true]) func nativeGlassKeepsItsOpticsAndMenuHierarchy(dark: Bool) {
        for placement in [AskGlassPlacement.floating, .inWindow, .menu] {
            let native = placement.frost(dark: dark, material: .liquidGlass)
            #expect(native > 0 && native < 0.35)
            #expect(native < placement.frost(dark: dark, material: .visualEffect))
        }
        #expect(AskGlassPlacement.menu.frost(dark: dark, material: .liquidGlass)
            > AskGlassPlacement.floating.frost(dark: dark, material: .liquidGlass))
    }

    @Test(arguments: [AskGlassMaterial.liquidGlass, .visualEffect, .opaque])
    func accessibilitySettingsOverrideEvenPinnedGlass(material: AskGlassMaterial) {
        #expect(AskGlassBackground.effectiveMaterial(material, reduceTransparency: true,
                                                   increasedContrast: false) == .opaque)
        #expect(AskGlassBackground.effectiveMaterial(material, reduceTransparency: false,
                                                   increasedContrast: true) == .opaque)
        #expect(AskGlassBackground.effectiveMaterial(material, reduceTransparency: false,
                                                   increasedContrast: false) == material)
    }

    @Test func floatingGlassBlursWhatIsBehindThePanel() {
        #expect(AskGlassPlacement.floating.blending == .behindWindow)
        #expect(AskGlassPlacement.floating.fallbackMaterial == .popover)
    }

    @Test func inWindowGlassBlursTheWindowsOwnContent() {
        #expect(AskGlassPlacement.inWindow.blending == .withinWindow)
        #expect(AskGlassPlacement.inWindow.fallbackMaterial == .popover)
    }

    @Test func floatingGlassKeepsBothAppearancesLegible() {
        let dark = AskGlassPlacement.floating.frost(dark: true)
        let light = AskGlassPlacement.floating.frost(dark: false)
        #expect(dark >= 0.75 && dark < 1)
        // GUL-327: light floating panels keep a stable surface over dark desktops.
        #expect(light == 0.92)
    }

    @Test(arguments: [false, true]) func inWindowChromeAndMenusRemainFrosted(dark: Bool) {
        // Frosted enough to keep text legible, clear enough for the backdrop's glows.
        #expect(AskGlassPlacement.inWindow.frost(dark: dark) >= 0.4)
        #expect(AskGlassPlacement.inWindow.frost(dark: dark) <= 0.6)
        // Menus sit over the transcript and need more frost than the window chrome.
        #expect(AskGlassPlacement.menu.frost(dark: dark) > AskGlassPlacement.inWindow.frost(dark: dark))
        #expect(AskGlassPlacement.menu.blending == .behindWindow)
        #expect(AskGlassPlacement.menu.fallbackMaterial == .menu)
    }

    @Test func inWindowComposerKeepsItsHairlineOnGlass() {
        let workspace = AskComposerChrome.workspace, launcher = AskComposerChrome.launcher
        for material in [AskGlassMaterial.liquidGlass, .visualEffect, .opaque] {
            #expect(workspace.idleBorder(on: material, increasedContrast: false) == AskTheme.border)
        }
        #expect(workspace.idleBorder(on: nil, increasedContrast: false) == AskTheme.border)
        // The launcher keeps the glass's own edge, plus a faint light-mode hairline.
        #expect(launcher.idleBorder(on: .liquidGlass, increasedContrast: false) == AskTheme.floatingGlassEdge)
        #expect(launcher.idleBorder(on: .liquidGlass, increasedContrast: true) == AskTheme.floatingBorder)
        #expect(launcher.idleBorder(on: .opaque, increasedContrast: false) == AskTheme.floatingBorder)
        #expect(launcher.idleBorder(on: nil, increasedContrast: false) == AskTheme.floatingBorder)
    }

    @Test func sidebarToolsPillLinesUpWithTheSearchField() {
        // The glass pill's trailing edge meets the search field's; classic buttons stand 8pt in.
        #expect(AskMetrics.sidebarToolsTrailing(glass: true) == AskMetrics.sidebarContentInset)
        #expect(AskMetrics.sidebarToolsTrailing(glass: false) == 8)
    }

    @Test func transcriptIsHiddenOutsideTheHeaderPills() {
        #expect(AskMetrics.headerCapsuleTop == (AskMetrics.titleBarRowHeight - AskMetrics.headerCapsuleHeight) / 2)
        let fade = AskEdgeFade(topClear: AskMetrics.headerCapsuleTop, bottomClear: AskMetrics.composerBottomInset,
                               fade: AskMetrics.transcriptEdgeFade)
        #expect(fade.topClear == AskMetrics.headerCapsuleTop)
        #expect(fade.bottomClear == AskMetrics.composerBottomInset)
        #expect(AskEdgeFade(fade: 10).topClear == 0)
    }

    @Test func glassBackgroundDefaultsToTheLaunchersPlacementAndCorner() {
        let background = AskGlassBackground(material: .visualEffect, corner: 26, opaqueFill: .clear)
        #expect(background.placement == .floating)
        #expect(background.cornerStyle == .continuous)
    }

    @Test func composerGlassCarriesItsChromesGeometryAndPlacement() {
        for chrome in [AskComposerChrome.launcher, .workspace] {
            for material in [AskGlassMaterial.liquidGlass, .visualEffect, .opaque] {
                let background = chrome.glassBackground(material)
                #expect(background.corner == chrome.corner)
                #expect(background.opaqueFill == chrome.fill)
                #expect(background.placement == chrome.placement)
                #expect(background.material == material)
            }
        }
    }

    @Test(arguments: [false, true]) func edgeColumnIsClearerGlassThanTheCanvas(dark: Bool) {
        let column = AskEdgeColumnBackdrop.tintOpacity(dark: dark)
        #expect(column > 0)
        #expect(column < AskWindowBackdrop.tintOpacity(dark: dark, reduceTransparency: false))
    }

    @Test func edgeColumnFollowsTheSharedOpaqueFallback() {
        #expect(AskEdgeColumnBackdrop.usesTransparency(materialOverride: nil, reduceTransparency: false,
                                                       increasedContrast: false))
        #expect(!AskEdgeColumnBackdrop.usesTransparency(materialOverride: nil, reduceTransparency: true,
                                                        increasedContrast: false))
        #expect(!AskEdgeColumnBackdrop.usesTransparency(materialOverride: nil, reduceTransparency: false,
                                                        increasedContrast: true))
        #expect(!AskEdgeColumnBackdrop.usesTransparency(materialOverride: .opaque, reduceTransparency: false,
                                                        increasedContrast: false))
        #expect(AskEdgeColumnBackdrop.usesTransparency(materialOverride: .visualEffect, reduceTransparency: false,
                                                       increasedContrast: false))
        // The opaque column still steps off the canvas in both appearances.
        #expect(AskEdgeColumnBackdrop.opaqueShade(dark: true) != AskEdgeColumnBackdrop.opaqueShade(dark: false))
    }

    @Test func usagePanelKeepsItsWidthAsAFlushColumn() {
        // Formerly a 330pt card inset 8pt from the edge; the flush column takes both.
        #expect(AskMetrics.usagePanelWidth == 338)
        let layout = AskWorkspaceLayout(size: CGSize(width: 1400, height: 900), sidebarCollapsed: false,
                                        showsUsage: true)
        #expect(layout.usageWidth == AskMetrics.usagePanelWidth)
    }

    @Test func selectedHistoryTitleTakesTheAccentOnGlass() {
        #expect(AskHistoryRow.titleColor(selected: true, hovering: false, stored: false, glass: true)
            == AskTheme.accent)
        #expect(AskHistoryRow.titleColor(selected: true, hovering: false, stored: true, glass: true)
            == AskTheme.privateTint)
        #expect(AskHistoryRow.titleColor(selected: true, hovering: false, stored: false, glass: false)
            == StudioTheme.textPrimary)
        #expect(AskHistoryRow.titleColor(selected: false, hovering: true, stored: false, glass: true)
            == StudioTheme.textPrimary)
        #expect(AskHistoryRow.titleColor(selected: false, hovering: false, stored: true, glass: true)
            == StudioTheme.textSecondary)
    }

    @Test func headerCapsulesFitTheTitleBarRow() {
        #expect(AskMetrics.headerCapsuleHeight < AskMetrics.titleBarRowHeight)
        #expect(AskMetrics.headerCapsuleHeight >= AskMetrics.composerControlHeight)
    }

    @Test func activityBlockStaysSofterThanTheComposer() {
        #expect(AskActivityBlock.corner > 0)
        #expect(AskActivityBlock.corner < AskComposerChrome.workspace.corner)
    }

    @Test func transcriptFollowsTheEndOnlyWhenItIsAboveTheComposer() {
        // 600pt viewport, composer and banners cover the bottom 120pt.
        #expect(AskPresentation.isFollowingBottom(markerTop: 480, viewport: 600, coveredBottom: 120))
        #expect(AskPresentation.isFollowingBottom(markerTop: 500, viewport: 600, coveredBottom: 120))
        #expect(!AskPresentation.isFollowingBottom(markerTop: 520, viewport: 600, coveredBottom: 120))
        // Hidden under the composer is not "at the end", although it is inside the viewport.
        #expect(!AskPresentation.isFollowingBottom(markerTop: 590, viewport: 600, coveredBottom: 120))
    }

    @Test func followingBottomWithoutChromeKeepsThePreviousTolerance() {
        #expect(AskPresentation.isFollowingBottom(markerTop: 624, viewport: 600, coveredBottom: 0))
        #expect(!AskPresentation.isFollowingBottom(markerTop: 625, viewport: 600, coveredBottom: 0))
        // A not-yet-measured (negative) height never widens the window.
        #expect(!AskPresentation.isFollowingBottom(markerTop: 625, viewport: 600, coveredBottom: -50))
    }

    @Test func bottomChromeHeightKeepsTheTallestReport() {
        var value: CGFloat = 40
        AskBottomChromeHeight.reduce(value: &value) { 120 }
        #expect(value == 120)
        AskBottomChromeHeight.reduce(value: &value) { 80 }
        #expect(value == 120)
        #expect(AskBottomChromeHeight.defaultValue == 0)
    }

    @Test func collapsedTitleClearsTheThreeButtonPill() {
        // Traffic lights, then a pill of toggle + search + compose (3pt padding each side).
        let pillEnd = AskMetrics.trafficLightInset + AskMetrics.titleBarButtonWidth * 3 + 6
        #expect(AskMetrics.collapsedTitleInset >= pillEnd + 8)
        #expect(AskTitleBarButton.size.width == AskMetrics.titleBarButtonWidth)
        #expect(AskTitleBarButton.size.height < AskMetrics.headerCapsuleHeight)
    }

    @Test func titleBarButtonHelpCarriesItsShortcut() {
        #expect(AskTitleBarButton.help(label: "新对话", shortcut: "⌘N") == "新对话 ⌘N")
        #expect(AskTitleBarButton.help(label: "搜索对话", shortcut: nil) == "搜索对话")
    }
}
