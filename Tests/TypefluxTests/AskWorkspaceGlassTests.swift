import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask workspace glass")
struct AskWorkspaceGlassTests {
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
        // Light glass stays clear enough to show the backdrop (GUL-252).
        #expect(light >= 0.65 && light <= 0.75)
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

    @Test func composerAndSidebarBottomsLineUp() {
        // Nothing sits under the composer card, which still clears the sidebar's bottom inset.
        #expect(AskMetrics.composerBottomInset > AskMetrics.sidebarPanelInset)
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

    @Test func accountNameLinesUpWithTheHistoryTitles() {
        // History rows: 8pt list inset + 10pt row padding.
        #expect(AskMetrics.sidebarTextLeading == 18)
    }

    @Test func sidebarPanelIsConcentricWithItsRows() {
        // History rows, search and "new chat" are inset 8pt from the panel edge,
        // so the panel corner wraps them at the same centre.
        #expect(AskMetrics.sidebarPanelCorner == AskMetrics.sidebarRowCorner + AskMetrics.sidebarPanelInset)
        #expect(AskMetrics.sidebarPanelInset > 0)
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
