import AppKit
import Testing
@testable import Typeflux

@Suite("Ask hover card", .exclusiveUIState)
@MainActor
struct AskHoverCardTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 260, height: 70)

    @Test func cardSitsAboveTheChipCentred() {
        let chip = NSRect(x: 600, y: 100, width: 28, height: 28)
        let frame = AskHoverCardPresenter.frame(size: size, anchor: chip, screen: screen)
        #expect(frame.midX == chip.midX)
        #expect(frame.minY == chip.maxY + AskHoverCardPresenter.gap)
        #expect(frame.size == size)
    }

    @Test func cardStaysOnScreen() {
        let left = AskHoverCardPresenter.frame(size: size, anchor: NSRect(x: 2, y: 100, width: 28, height: 28), screen: screen)
        #expect(left.minX == screen.minX + AskHoverCardPresenter.screenMargin)
        let right = AskHoverCardPresenter.frame(size: size, anchor: NSRect(x: 1430, y: 100, width: 28, height: 28), screen: screen)
        #expect(right.maxX == screen.maxX - AskHoverCardPresenter.screenMargin)
        // No room above: flip below the chip.
        let top = NSRect(x: 600, y: 860, width: 28, height: 28)
        let flipped = AskHoverCardPresenter.frame(size: size, anchor: top, screen: screen)
        #expect(flipped.maxY == top.minY - AskHoverCardPresenter.gap)
    }

    /// The regression: a popover took the click and key status from the chip.
    @Test func cardPanelNeverTakesClicksOrFocus() {
        let panel = AskHoverCardPresenter.makePanel()
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isOpaque)
    }

    @Test func hidingWithoutACardIsHarmless() {
        // No card is showing, so hide is a no-op for any owner and must not crash.
        AskHoverCardPresenter.shared.hide(owner: UUID())
    }
}
