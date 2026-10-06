import AppKit
import Testing
@testable import Typeflux

@Suite("Ask launcher dragging", .serialized)
@MainActor
struct AskLauncherDragTests {
    private func event(_ type: NSEvent.EventType, clicks: Int = 1, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: clicks, pressure: 1))
    }

    private func dragArea(in window: NSWindow) -> AskWindowDragView {
        let view = AskWindowDragView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(view)
        return view
    }

    @Test func draggingMovesTheWindowByThePointersTravel() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = dragArea(in: window)
        var mouse = NSPoint(x: 250, y: 350)
        var proposals: [NSPoint] = []
        var ended = 0
        view.mouseLocation = { mouse }
        view.handlers = AskWindowDragHandlers(move: { proposals.append($0); return NSPoint(x: $0.x, y: $0.y - 1) },
                                              end: { ended += 1 })
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(!view.mouseDownCanMoveWindow)

        view.mouseDown(with: try event(.leftMouseDown, in: window))
        mouse = NSPoint(x: 300, y: 330)
        view.mouseDragged(with: try event(.leftMouseDragged, in: window))
        #expect(proposals == [NSPoint(x: 250, y: 280)])
        // The controller's answer is where the window goes.
        #expect(window.frame.origin == NSPoint(x: 250, y: 279))
        #expect(ended == 0)

        view.mouseUp(with: try event(.leftMouseUp, in: window))
        #expect(ended == 1)
        // Later drags without a press are ignored.
        view.mouseDragged(with: try event(.leftMouseDragged, in: window))
        #expect(proposals.count == 1)
    }

    @Test func aClickWithoutMovingIsNotADrag() throws {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let view = dragArea(in: window)
        var ended = 0, resets = 0
        view.handlers = AskWindowDragHandlers(end: { ended += 1 }, reset: { resets += 1 })
        view.mouseDown(with: try event(.leftMouseDown, in: window))
        view.mouseUp(with: try event(.leftMouseUp, in: window))
        #expect(ended == 0)
        #expect(window.frame.origin == NSPoint(x: 200, y: 300))

        view.mouseDown(with: try event(.leftMouseDown, clicks: 2, in: window))
        view.mouseUp(with: try event(.leftMouseUp, clicks: 2, in: window))
        #expect(resets == 1)
        #expect(ended == 0)
    }
}

@Suite("Ask launcher position", .serialized)
@MainActor
struct AskLauncherPositionTests {

    /// The screen `showLauncher` opens on: the one with the pointer.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    private func settings() throws -> SettingsStore {
        SettingsStore(defaults: try #require(UserDefaults(suiteName: "AskLauncherPositionTests-\(UUID().uuidString)")))
    }

    @Test func centredByDefaultEvenAfterBeingDragged() async throws {
        _ = NSApplication.shared
        let screen = try #require(screen)
        let f = try AskTestFixture(authenticated: false)
        let settings = try settings()
        let controller = AskConversationWindowController(settings: settings, model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }

        controller.showLauncher()
        let launcher = try #require(controller.launcherWindow)
        let centred = launcher.frame
        #expect(abs(centred.midX - screen.visibleFrame.midX) <= 1)

        launcher.setFrameOrigin(NSPoint(x: centred.minX - 200, y: centred.minY - 100))
        controller.finishLauncherDrag()
        #expect(settings.askLauncherAnchors.isEmpty, "centring never remembers")

        controller.dismissLauncher()
        controller.showLauncher()
        #expect(controller.launcherWindow?.frame.origin == centred.origin)
    }

    @Test func remembersWhereItWasLeftAndGrowsDownFromThere() async throws {
        _ = NSApplication.shared
        let screen = try #require(screen)
        let f = try AskTestFixture(authenticated: false)
        let settings = try settings()
        settings.askLauncherPosition = .lastPosition
        let controller = AskConversationWindowController(settings: settings, model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }

        controller.showLauncher()
        let launcher = try #require(controller.launcherWindow)
        let visible = screen.visibleFrame
        let moved = NSPoint(x: visible.minX + 40, y: launcher.frame.minY - 60)
        launcher.setFrameOrigin(controller.dragLauncher(to: moved))
        controller.finishLauncherDrag()
        let key = AskLauncherPlacement.key(for: screen)
        let anchor = try #require(settings.askLauncherAnchors[key])
        #expect(anchor == AskLauncherPlacement.anchor(of: launcher.frame, on: visible))

        controller.dismissLauncher()
        controller.showLauncher()
        let reopened = try #require(controller.launcherWindow).frame
        #expect(reopened.minX == visible.minX + 40)
        #expect(reopened.maxY == visible.maxY - anchor.fromTop)
    }

    @Test func draggingSnapsToTheCentreLineAndStaysOnScreen() async throws {
        _ = NSApplication.shared
        let screen = try #require(screen)
        let f = try AskTestFixture(authenticated: false)
        let controller = AskConversationWindowController(settings: try settings(), model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }

        controller.showLauncher()
        let launcher = try #require(controller.launcherWindow)
        let visible = screen.visibleFrame
        let centred = (visible.midX - launcher.frame.width / 2).rounded()
        #expect(controller.dragLauncher(to: NSPoint(x: centred + 5, y: 200)).x == centred)

        // Let go half off the right edge: it comes back inside.
        launcher.setFrameOrigin(NSPoint(x: visible.maxX - 100, y: launcher.frame.minY))
        controller.finishLauncherDrag()
        #expect(launcher.frame.maxX == visible.maxX - AskLauncherPlacement.screenMargin)
    }

    @Test func theTopEdgeAndTheBarsEmptySpaceGrabThePanel() async throws {
        _ = NSApplication.shared
        let f = try AskTestFixture(authenticated: false)
        let controller = AskConversationWindowController(settings: try settings(), model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }
        controller.showLauncher()
        let launcher = try #require(controller.launcherWindow)
        let content = try #require(launcher.contentView)
        content.layoutSubtreeIfNeeded()
        func hit(_ point: NSPoint) -> NSView? { content.hitTest(content.convert(point, to: content.superview)) }
        func grabs(_ point: NSPoint) -> Bool {
            var view = hit(point)
            while let current = view, !(current is AskWindowDragView) { view = current.superview }
            return view != nil
        }
        let size = content.bounds.size
        let gutter = AskMetrics.launcherGutter
        // The hosting view is flipped; measure from the panel's top or bottom edge either way.
        func top(_ distance: CGFloat) -> CGFloat { content.isFlipped ? distance : size.height - distance }
        func bottom(_ distance: CGFloat) -> CGFloat { top(size.height - distance) }
        #expect(grabs(NSPoint(x: size.width / 2, y: top(gutter + 4))), "the top edge of the card")
        #expect(grabs(NSPoint(x: size.width / 2 + 40, y: bottom(gutter + 21))), "the bottom bar between its tools and hint")
        #expect(!grabs(NSPoint(x: size.width / 2, y: top(gutter + 30))), "the editor row stays typeable")
        #expect(!grabs(NSPoint(x: 20, y: bottom(gutter + 21))), "the bar's own buttons still click")
    }

    @Test func doubleClickingTheTopEdgeCentresAndForgets() async throws {
        _ = NSApplication.shared
        let screen = try #require(screen)
        let f = try AskTestFixture(authenticated: false)
        let settings = try settings()
        settings.askLauncherPosition = .lastPosition
        let key = AskLauncherPlacement.key(for: screen)
        settings.askLauncherAnchors[key] = .init(left: 30, fromTop: 30)
        settings.askLauncherAnchors["another display"] = .init(left: 30, fromTop: 30)
        let controller = AskConversationWindowController(settings: settings, model: f.model)
        defer { controller.dismissLauncher(); f.model.resetSession() }

        controller.showLauncher()
        let launcher = try #require(controller.launcherWindow)
        #expect(launcher.frame.minX == screen.visibleFrame.minX + 30)

        controller.recenterLauncher()
        #expect(abs(launcher.frame.midX - screen.visibleFrame.midX) <= 1)
        #expect(launcher.frame.maxY == AskLauncherPlacement.top(on: screen.visibleFrame))
        #expect(settings.askLauncherAnchors[key] == nil)
        #expect(settings.askLauncherAnchors["another display"] != nil, "other displays keep theirs")
    }
}

