import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask glass menu", .serialized)
@MainActor
struct AskGlassMenuTests {
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func opensAboveTheButtonWithLeadingEdgesAligned() {
        let anchor = NSRect(x: 400, y: 100, width: 120, height: 32)
        let frame = AskGlassMenuPresenter.frame(size: NSSize(width: 320, height: 300), anchor: anchor, screen: screen)
        #expect(frame.minY == anchor.maxY + AskGlassMenuPresenter.gap)
        #expect(frame.minX == anchor.minX - AskGlassMenuPresenter.leadingOffset)
        #expect(frame.size == NSSize(width: 320, height: 300))
    }

    @Test func dropsBelowWhenThereIsNoRoomAbove() {
        let anchor = NSRect(x: 400, y: 800, width: 120, height: 32)
        let frame = AskGlassMenuPresenter.frame(size: NSSize(width: 320, height: 300), anchor: anchor, screen: screen)
        #expect(frame.maxY == anchor.minY - AskGlassMenuPresenter.gap)
    }

    @Test func staysOnScreenAtTheEdges() {
        let right = AskGlassMenuPresenter.frame(size: NSSize(width: 320, height: 100),
                                                anchor: NSRect(x: 1400, y: 100, width: 30, height: 32), screen: screen)
        #expect(right.maxX == screen.maxX - AskGlassMenuPresenter.screenMargin)
        let left = AskGlassMenuPresenter.frame(size: NSSize(width: 320, height: 100),
                                               anchor: NSRect(x: 0, y: 100, width: 30, height: 32), screen: screen)
        #expect(left.minX == screen.minX + AskGlassMenuPresenter.screenMargin)
        // Taller than the space on either side: pinned to the bottom margin rather than off screen.
        let tall = AskGlassMenuPresenter.frame(size: NSSize(width: 320, height: 880),
                                               anchor: NSRect(x: 400, y: 400, width: 30, height: 32), screen: screen)
        #expect(tall.minY >= screen.minY + AskGlassMenuPresenter.screenMargin)
        #expect(AskGlassMenuPresenter.frame(size: NSSize(width: 10, height: 10), anchor: .zero, screen: nil).origin
            == NSPoint(x: -AskGlassMenuPresenter.leadingOffset, y: AskGlassMenuPresenter.gap))
    }

    @Test func showsAsAnArrowlessChildPanelAndClosesExactlyOnce() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 32))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }

        let presenter = AskGlassMenuPresenter()
        var closes = 0
        let owner = UUID()
        presenter.show(Text("menu").frame(width: 200, height: 120), owner: owner, anchor: anchor) { closes += 1 }
        let panel = try #require(presenter.panel)
        #expect(presenter.isShowing)
        #expect(panel.parent === window)
        #expect(!panel.canBecomeKey)
        #expect(panel.frame.minY > window.frame.minY + 20)

        // Clicks on the menu or on its own button leave it open; anywhere else closes it.
        #expect(!presenter.shouldClose(forClickIn: panel, at: NSPoint(x: panel.frame.midX, y: panel.frame.midY)))
        let button = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        #expect(!presenter.shouldClose(forClickIn: window, at: NSPoint(x: button.midX, y: button.midY)))
        #expect(presenter.shouldClose(forClickIn: window, at: NSPoint(x: window.frame.maxX - 5, y: window.frame.maxY - 5)))

        presenter.hide(owner: UUID()) // someone else's menu: ignored
        #expect(presenter.isShowing && closes == 0)
        presenter.hide(owner: owner)
        #expect(!presenter.isShowing)
        #expect(closes == 1)
        #expect(panel.parent == nil && !panel.isVisible)
        presenter.hide()
        #expect(closes == 1)
        #expect(!presenter.shouldClose(forClickIn: window, at: .zero))
    }

    @Test func refusesToShowForAnAnchorWithoutAWindow() {
        let presenter = AskGlassMenuPresenter()
        var closed = false
        presenter.show(Text("menu"), owner: UUID(), anchor: NSView()) { closed = true }
        #expect(!presenter.isShowing)
        #expect(closed)
    }

    @Test func footerOnlyOffersMakingANewDefault() {
        #expect(AskModelChoices.offersMakeDefault(showsDefaultAction: true, selectionAvailable: true,
                                                  reference: "cloud:a", defaultReference: "cloud:b"))
        #expect(!AskModelChoices.offersMakeDefault(showsDefaultAction: true, selectionAvailable: true,
                                                   reference: "cloud:a", defaultReference: "cloud:a"))
        #expect(!AskModelChoices.offersMakeDefault(showsDefaultAction: true, selectionAvailable: false,
                                                   reference: "cloud:a", defaultReference: "cloud:b"))
        #expect(!AskModelChoices.offersMakeDefault(showsDefaultAction: false, selectionAvailable: true,
                                                   reference: "cloud:a", defaultReference: "cloud:b"))
    }
}
