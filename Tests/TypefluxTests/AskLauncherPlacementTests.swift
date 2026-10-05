import AppKit
import Testing
@testable import Typeflux

@Suite("Ask launcher placement")
struct AskLauncherPlacementTests {
    private let screen = NSRect(x: 0, y: 40, width: 1512, height: 900)

    @Test func emptyLauncherIsCentredOnTheScreen() {
        let height = AskLauncherPlacement.restingHeight
        let frame = AskLauncherPlacement.frame(height: height, width: 680, screen: screen)
        #expect(abs(frame.midX - screen.midX) <= 0.5)
        #expect(abs(frame.midY - screen.midY) <= 1)
        #expect(frame.height == height && frame.width == 680)
    }

    @Test func shorterOrTallerLaunchersShareTheSameTopEdge() {
        let resting = AskLauncherPlacement.frame(height: AskLauncherPlacement.restingHeight, width: 680, screen: screen)
        let typed = AskLauncherPlacement.frame(height: 114, width: 680, screen: screen)
        #expect(typed.maxY == resting.maxY)
    }

    @Test func resizingKeepsTheTopAndGrowsDownward() {
        let start = NSRect(x: 416, y: 300, width: 680, height: 114)
        let grown = AskLauncherPlacement.resized(start, height: 230, screen: screen)
        #expect(grown.maxY == start.maxY)
        #expect(grown.minY == start.maxY - 230)
        #expect(grown.minX == start.minX && grown.width == start.width)
        #expect(AskLauncherPlacement.resized(start, height: 230, screen: nil).maxY == start.maxY)
    }

    @Test func resizingReturnsToTheEdgeItOpenedWith() {
        let top = AskLauncherPlacement.top(on: screen)
        #expect(AskLauncherPlacement.frame(height: 114, width: 680, screen: screen).maxY == top)
        // Pushed up to fit a tall panel, it comes back down once it is short again.
        let raised = NSRect(x: 416, y: 600, width: 680, height: 114)
        let back = AskLauncherPlacement.resized(raised, height: 114, top: top, screen: screen)
        #expect(back.maxY == top)
        #expect(back.minX == raised.minX && back.height == 114)
        let tall = AskLauncherPlacement.resized(raised, height: 800, top: top, screen: screen)
        #expect(tall.minY >= screen.minY + AskLauncherPlacement.screenMargin, "still clamped to the screen")
    }

    @Test func aTallPanelStaysOnScreen() {
        let low = NSRect(x: 416, y: 60, width: 680, height: 114)
        let grown = AskLauncherPlacement.resized(low, height: 400, screen: screen)
        #expect(grown.minY == screen.minY + AskLauncherPlacement.screenMargin)
        let huge = AskLauncherPlacement.clamped(NSRect(x: 0, y: 0, width: 680, height: 2000), screen: screen)
        #expect(huge.minY == screen.minY + AskLauncherPlacement.screenMargin)
        let high = AskLauncherPlacement.clamped(NSRect(x: 0, y: 900, width: 680, height: 200), screen: screen)
        #expect(high.maxY == screen.maxY - AskLauncherPlacement.screenMargin)
    }
}
