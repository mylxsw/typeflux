import AppKit
import Testing
@testable import Typeflux

@Suite("Clipboard panel placement")
struct ClipboardPanelPlacementTests {
    private let screen = NSRect(x: 0, y: 40, width: 1512, height: 900)
    private let size = NSSize(width: 640, height: 560)

    @Test func searchCardSharesTheLauncherVisibleTopEdge() {
        let launcher = AskLauncherPlacement.frame(
            height: AskLauncherPlacement.restingHeight, width: 680, screen: screen
        )
        let clipboard = ClipboardPanelPlacement.frame(size: size, screen: screen)
        #expect(clipboard.maxY == launcher.maxY - AskMetrics.launcherGutter)
        #expect(clipboard.midX == screen.midX)
        #expect(clipboard.size == size)
    }

    @Test func rememberedLauncherHeightKeepsClipboardHorizontallyCentred() {
        let anchor = AskLauncherPlacement.Anchor(left: 100, fromTop: 100)
        let clipboard = ClipboardPanelPlacement.frame(size: size, screen: screen, launcherAnchor: anchor)
        #expect(clipboard.maxY == screen.maxY - 100 - AskMetrics.launcherGutter)
        #expect(clipboard.midX == screen.midX)
        #expect(clipboard.size == size)
    }

    @Test func externalDisplayUsesItsOwnCoordinates() {
        let external = NSRect(x: -1920, y: -200, width: 1920, height: 1050)
        let launcher = AskLauncherPlacement.frame(height: 114, width: 680, screen: external)
        let clipboard = ClipboardPanelPlacement.frame(size: size, screen: external)
        #expect(clipboard.maxY == launcher.maxY - AskMetrics.launcherGutter)
        #expect(clipboard.midX == external.midX)
        #expect(external.contains(clipboard))
    }

    @Test func shortScreenRaisesClipboardToKeepTheBottomVisible() {
        let small = NSRect(x: 0, y: 30, width: 1200, height: 650)
        let clipboard = ClipboardPanelPlacement.frame(size: size, screen: small)
        #expect(clipboard.minY == small.minY + AskLauncherPlacement.screenMargin)
        #expect(clipboard.maxY <= small.maxY - AskLauncherPlacement.screenMargin)
        #expect(clipboard.size == size)
    }

    @Test func offscreenRememberedHeightStaysWithinUsableEdges() {
        for fromTop: CGFloat in [-100, 2000] {
            let clipboard = ClipboardPanelPlacement.frame(
                size: size, screen: screen,
                launcherAnchor: AskLauncherPlacement.Anchor(left: 0, fromTop: fromTop)
            )
            #expect(clipboard.minY >= screen.minY + AskLauncherPlacement.screenMargin)
            #expect(clipboard.maxY <= screen.maxY - AskLauncherPlacement.screenMargin)
            #expect(clipboard.midX == screen.midX)
            #expect(clipboard.size == size)
        }
    }
}
