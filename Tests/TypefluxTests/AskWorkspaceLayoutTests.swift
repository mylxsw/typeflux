import Foundation
import Testing
@testable import Typeflux

@Suite("Ask responsive layout")
struct AskWorkspaceLayoutTests {
    @Test(arguments: [CGSize(width: 1180, height: 760), CGSize(width: 760, height: 560),
                      CGSize(width: 440, height: 880), CGSize(width: 960, height: 320),
                      CGSize(width: 440, height: 320), AskWorkspaceLayout.minimumWindowSize])
    func columnsFitEverySupportedViewport(_ size: CGSize) {
        for collapsed in [false, true] {
            for usage in [false, true] {
                let layout = AskWorkspaceLayout(size: size, sidebarCollapsed: collapsed, showsUsage: usage)
                let occupied = layout.mainWidth + (layout.sidebarInline ? AskMetrics.sidebarWidth : 0)
                    + (layout.usageInline ? layout.usageWidth : 0)
                #expect(occupied == size.width)
                #expect(layout.mainWidth >= 360)
                #expect(layout.composerWidth <= min(layout.mainWidth, AskMetrics.composerMaxWidth))
                #expect(layout.composerWidth >= 336)
                #expect(layout.composerAvailableHeight + layout.composerTopInset
                    + layout.composerBottomInset + AskMetrics.titleBarRowHeight == size.height)
                #expect(layout.drawerWidth <= size.width - 16)
                #expect(size.width - layout.drawerWidth >= AskMetrics.trafficLightInset
                    || layout.usageOverlayTopInset >= AskMetrics.titleBarRowHeight - 8)
                #expect(layout.usageOverlay == (usage && !layout.usageInline))
                if collapsed { #expect(!layout.sidebarInline) }
            }
        }
    }

    @Test func panelsYieldBeforeShrinkingTheReadingColumn() {
        func layout(_ width: CGFloat, usage: Bool = false) -> AskWorkspaceLayout {
            .init(size: CGSize(width: width, height: 760), sidebarCollapsed: false, showsUsage: usage)
        }
        #expect(!layout(863).sidebarInline)
        #expect(layout(864).sidebarInline)
        #expect(layout(937, usage: true).usageOverlay)
        #expect(layout(938, usage: true).usageInline)
        #expect(!layout(1201, usage: true).sidebarInline)
        #expect(layout(1202, usage: true).sidebarInline)
        #expect(layout(1202, usage: true).mainWidth == 600)
        #expect(layout(440).compactContent)
        #expect(!layout(600).compactContent)
    }

    @Test func heightDensityIsIndependentOfWidthAndPanelState() {
        for width: CGFloat in [360, 440, 960, 1440] {
            for height: CGFloat in [280, 320, 359, 360, 499, 500, 880] {
                let layout = AskWorkspaceLayout(size: CGSize(width: width, height: height),
                                                sidebarCollapsed: false, showsUsage: true)
                #expect(layout.isShort == (height < 500))
                #expect(layout.isVeryShort == (height < 360))
                #expect(layout.composerBottomInset == (height < 500 ? 8 : AskMetrics.composerBottomInset))
                #expect(layout.horizontalInset == (layout.compactContent ? 14 : AskMetrics.columnInset))
            }
        }
    }

    @Test func unmeasuredViewportDoesNotCreateNegativeFrames() {
        let layout = AskWorkspaceLayout(size: .zero, sidebarCollapsed: false, showsUsage: true)
        #expect(layout.mainWidth == 0)
        #expect(layout.composerAvailableHeight == 0)
        #expect(layout.drawerWidth == 0)
        #expect(!layout.sidebarInline)
        #expect(!layout.usageInline)
    }

    @Test func searchPaletteFitsShortWindowsAndCapsTallOnes() {
        for height: CGFloat in [280, 320, 499, 500, 880] {
            let inset = AskSearchPaletteView.topInset(in: height)
            let list = AskSearchPaletteView.listHeight(in: height)
            #expect(inset + 55 + list + 12 <= height)
            #expect(list > 0 && list <= AskSearchPaletteView.listMaxHeight)
        }
        #expect(AskSearchPaletteView.listHeight(in: 0) == 0)
    }
}
