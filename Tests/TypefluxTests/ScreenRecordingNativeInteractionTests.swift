import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenRecordingNativeInteractionTests {
    @Test func `region mouse interactions share screenshot move and resize geometry`() async throws {
        _ = NSApplication.shared
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.selectSourceKind(.region)
        let view = ScreenRecordingSelectionView(
            frame: CGRect(x: -800, y: 0, width: 800, height: 600),
            displayID: 1,
            scale: 2,
            model: fixture.model
        )
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.orderOut(nil); window.close() }
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 100, y: 100), view: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, point: CGPoint(x: 500, y: 400), view: view))
        try view.mouseUp(with: mouse(.leftMouseUp, point: CGPoint(x: 500, y: 400), view: view))
        #expect(fixture.model.selectedSource?.frame == CGRect(x: -700, y: 100, width: 400, height: 300))
        #expect(fixture.model.outputSize == CGSize(width: 800, height: 600))
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 200, y: 200), view: view))
        try view.mouseDragged(with: mouse(.leftMouseDragged, point: CGPoint(x: 250, y: 250), view: view))
        try view.mouseUp(with: mouse(.leftMouseUp, point: CGPoint(x: 250, y: 250), view: view))
        #expect(fixture.model.selectedSource?.frame.origin == CGPoint(x: -650, y: 150))
        let context = try #require(CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: 600); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = try NSBitmapImageRep(cgImage: #require(context.makeImage()))
        #expect(try #require(bitmap.colorAt(x: 10, y: 10)).alphaComponent > 0.3)
        #expect(try #require(bitmap.colorAt(x: 300, y: 300)).alphaComponent < 0.1)
        let outline = try #require(bitmap.colorAt(x: 300, y: 150)?.usingColorSpace(.sRGB))
        #expect(outline.redComponent > 0.5)
        #expect(abs(outline.redComponent - outline.greenComponent) < 0.01)
        #expect(abs(outline.redComponent - outline.blueComponent) < 0.01)
        let handle = try #require(bitmap.colorAt(x: 150, y: 150)?.usingColorSpace(.sRGB))
        #expect(handle.alphaComponent > 0.5 && handle.redComponent < 0.5)
        try ScreenshotSnapshotSupport.write(#require(bitmap.cgImage), name: "recording-overlay-region")
        try view.keyDown(with: key(code: 48, text: "\t", window: window))
        #expect(fixture.model.sourceKind == .window)
        try view.mouseMoved(with: mouse(.mouseMoved, point: CGPoint(x: 300, y: 300), view: view))
        #expect(view.hovered == nil)
        try view.keyDown(with: key(code: 48, text: "\t", window: window))
        #expect(fixture.model.sourceKind == .display)
        await fixture.clean()
    }

    @Test func `right toolbar grip moves its window and survives selection refreshes`() async throws {
        _ = NSApplication.shared
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.selectSourceKind(.region)
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        defer { presenter.hide() }
        try await Task.sleep(for: .milliseconds(150))
        let window = try #require(presenter.window)
        let content = try #require(window.contentView)
        func grip(in view: NSView) -> ScreenRecordingToolbarDragView? {
            if let view = view as? ScreenRecordingToolbarDragView { return view }
            return view.subviews.lazy.compactMap { grip(in: $0) }.first
        }
        let handle = try #require(grip(in: content))
        #expect(handle.acceptsFirstMouse(for: nil))
        handle.resetCursorRects()
        let handleFrame = handle.convert(handle.bounds, to: content)
        #expect(handleFrame.midX > content.bounds.midX)
        #expect(handleFrame.width == 16 && handleFrame.height == 30)
        let hitPoint = handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: content.superview)
        let hit = content.hitTest(hitPoint)
        #expect(hit === handle)
        var pointer = window.frame.origin
        handle.pointerLocation = { pointer }
        let original = window.frame
        // A drag without a preceding press must not move the panel.
        try handle.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: handle))
        #expect(window.frame == original)
        try handle.mouseDown(with: mouse(.leftMouseDown, point: .zero, view: handle))
        pointer.x += 4; pointer.y += 60
        try handle.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: handle))
        presenter.syncChrome()
        #expect(window.frame.origin == CGPoint(x: original.minX + 4, y: original.minY + 60))
        pointer.y += 30
        try handle.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: handle))
        try handle.mouseUp(with: mouse(.leftMouseUp, point: .zero, view: handle))
        let moved = window.frame
        #expect(moved.minY == original.minY + 90)
        pointer.y += 10
        try handle.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: handle))
        #expect(window.frame == moved)
        // Moving/resizing the capture region must leave the independently positioned toolbar usable.
        let screen = try #require(presenter.activeScreen)
        let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let selection = try #require(presenter.selectionViews.first { $0.displayID == displayID.uint32Value })
        try selection.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 100, y: 100), view: selection))
        try selection.mouseDragged(with: mouse(.leftMouseDragged, point: CGPoint(x: 500, y: 400), view: selection))
        try selection.mouseUp(with: mouse(.leftMouseUp, point: CGPoint(x: 500, y: 400), view: selection))
        presenter.syncChrome()
        #expect(window.frame == moved)
        try handle.mouseDown(with: mouse(.leftMouseDown, point: .zero, view: handle))
        pointer.y -= 20
        try handle.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: handle))
        try handle.mouseUp(with: mouse(.leftMouseUp, point: .zero, view: handle))
        #expect(window.frame.minY == moved.minY - 20)
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    @Test func `window hover commits a window instead of its desktop bounds`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        fixture.model.selectSourceKind(.window)
        let view = ScreenRecordingSelectionView(
            frame: CGRect(x: 0, y: 0, width: 1200, height: 720),
            displayID: 1,
            scale: 2,
            model: fixture.model
        )
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let event = try mouse(.mouseMoved, point: CGPoint(x: 200, y: 200), view: view)
        view.mouseMoved(with: event)
        #expect(view.hovered?.target == .window(2))
        #expect(!fixture.model.canStart)
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 200, y: 200), view: view))
        #expect(fixture.model.selectedSource?.target == .window(2))
        #expect(fixture.model.canStart)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        view.updateTrackingAreas()
        #expect(!view.trackingAreas.isEmpty)
        await fixture.clean()
    }

    @Test func `camera dragging snaps to corners and resizing changes encoded fraction`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.setup()
        var pointer = CGPoint(x: 150, y: 150)
        let view = ScreenRecordingCameraBubbleView(model: fixture.model, pointerLocation: { pointer })
        let target = CGRect(x: 100, y: 100, width: 800, height: 600)
        view.targetFrame = target
        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 120, width: 176, height: 132),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: 60, y: 60), view: view))
        pointer = CGPoint(x: 750, y: 650)
        try view.mouseDragged(with: mouse(.leftMouseDragged, point: CGPoint(x: 60, y: 60), view: view))
        try view.mouseUp(with: mouse(.leftMouseUp, point: CGPoint(x: 60, y: 60), view: view))
        #expect(fixture.model.options.cameraCorner == .topRight)
        #expect(target.contains(window.frame))
        pointer = CGPoint(x: 750, y: 650)
        try view.mouseDown(with: mouse(.leftMouseDown, point: CGPoint(x: view.bounds.maxX - 6, y: 6), view: view))
        pointer.x += 100
        try view.mouseDragged(with: mouse(.leftMouseDragged, point: .zero, view: view))
        try view.mouseUp(with: mouse(.leftMouseUp, point: .zero, view: view))
        #expect(abs(fixture.model.options.cameraFraction - 0.345) < 0.001)
        #expect(!view.isDragging)
        await fixture.clean()
    }

    @Test func `editor shortcuts ignore typing in the filename field`() async throws {
        let fixture = ScreenRecordingCoordinatorTests.Fixture()
        await fixture.recording()
        fixture.model.stop(); await fixture.model.pendingTask?.value
        let presenter = ScreenRecordingWindowController(preview: ScreenRecordingVisualTests.Devices())
        presenter.show(fixture.model)
        let window = try #require(presenter.window)
        #expect(try presenter.handleEditorKey(key(code: 49, text: " ", window: window)))
        try await fixture.waitForPlayback { fixture.model.isPlaying && !fixture.model.playback.isBusy }
        #expect(fixture.model.isPlaying)
        #expect(try presenter.handleEditorKey(key(code: 49, text: " ", window: window)))
        try await fixture.waitForPlayback { !fixture.model.isPlaying && !fixture.model.playback.isBusy }
        #expect(!fixture.model.isPlaying)
        fixture.model.seek(0.2)
        try await fixture.waitForPlayback { abs(fixture.model.currentTime - 0.2) < 0.001 && !fixture.model.playback.isBusy }
        #expect(try presenter.handleEditorKey(key(code: 34, text: "i", window: window)))
        #expect(fixture.model.trimStart == 0.2)
        let text = NSTextView(frame: .zero)
        window.contentView?.addSubview(text); window.makeFirstResponder(text)
        #expect(try !presenter.handleEditorKey(key(code: 34, text: "i", window: window)))
        presenter.hide(); await presenter.deviceTask?.value
        await fixture.clean()
    }

    private func mouse(_ type: NSEvent.EventType, point: CGPoint, view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
    }

    private func key(code: UInt16, text: String, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: text,
            charactersIgnoringModifiers: text,
            isARepeat: false,
            keyCode: code
        ))
    }
}
