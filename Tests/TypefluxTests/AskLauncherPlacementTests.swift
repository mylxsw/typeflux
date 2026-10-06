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

    @Test func aRememberedAnchorOpensWhereItWasLeft() {
        let anchor = AskLauncherPlacement.Anchor(left: 100, fromTop: 80)
        let frame = AskLauncherPlacement.frame(height: 114, width: 680, screen: screen, anchor: anchor)
        #expect(frame.minX == screen.minX + 100)
        #expect(frame.maxY == screen.maxY - 80)
        #expect(AskLauncherPlacement.top(on: screen, anchor: anchor) == frame.maxY)
        #expect(AskLauncherPlacement.anchor(of: frame, on: screen) == anchor)
    }

    @Test func anchorsAreMeasuredFromTheScreensOwnCorner() {
        // A second display to the left of and below the main one.
        let external = NSRect(x: -1920, y: -200, width: 1920, height: 1050)
        let frame = NSRect(x: -1500, y: 400, width: 680, height: 114)
        let anchor = AskLauncherPlacement.anchor(of: frame, on: external)
        #expect(anchor == AskLauncherPlacement.Anchor(left: 420, fromTop: 336))
        #expect(AskLauncherPlacement.frame(height: 114, width: 680, screen: external, anchor: anchor) == frame)
    }

    @Test func anAnchorOffTheScreenIsPulledBackInside() {
        // Saved on a larger display, or before the Dock grew.
        let far = AskLauncherPlacement.Anchor(left: 1400, fromTop: 2000)
        let frame = AskLauncherPlacement.frame(height: 114, width: 680, screen: screen, anchor: far)
        let margin = AskLauncherPlacement.screenMargin
        #expect(frame.maxX == screen.maxX - margin)
        #expect(frame.minY == screen.minY + margin)
        let before = AskLauncherPlacement.Anchor(left: -300, fromTop: -50)
        let pulled = AskLauncherPlacement.frame(height: 114, width: 680, screen: screen, anchor: before)
        #expect(pulled.minX == screen.minX + margin)
        #expect(pulled.maxY == screen.maxY - margin)
    }

    @Test func clampingKeepsThePanelBetweenTheSideEdges() {
        let margin = AskLauncherPlacement.screenMargin
        let right = AskLauncherPlacement.clamped(NSRect(x: 1400, y: 300, width: 680, height: 114), screen: screen)
        #expect(right.maxX == screen.maxX - margin)
        let left = AskLauncherPlacement.clamped(NSRect(x: -100, y: 300, width: 680, height: 114), screen: screen)
        #expect(left.minX == screen.minX + margin)
        let inside = NSRect(x: 300, y: 300, width: 680, height: 114)
        #expect(AskLauncherPlacement.clamped(inside, screen: screen) == inside)
    }

    @Test func draggingNearTheCentreLineSnapsOntoIt() {
        let centred = (screen.midX - 340).rounded()
        let near = AskLauncherPlacement.snapped(origin: NSPoint(x: centred + 7, y: 420), width: 680, screen: screen)
        #expect(near == NSPoint(x: centred, y: 420))
        let below = AskLauncherPlacement.snapped(origin: NSPoint(x: centred - 8, y: 10), width: 680, screen: screen)
        #expect(below.x == centred)
        let away = NSPoint(x: centred + 9, y: 420)
        #expect(AskLauncherPlacement.snapped(origin: away, width: 680, screen: screen) == away)
    }

    @Test @MainActor func everyDisplayHasAStableKey() throws {
        _ = NSApplication.shared
        let display = try #require(NSScreen.main ?? NSScreen.screens.first)
        let key = AskLauncherPlacement.key(for: display)
        #expect(!key.isEmpty)
        #expect(AskLauncherPlacement.key(for: display) == key)
    }
}
