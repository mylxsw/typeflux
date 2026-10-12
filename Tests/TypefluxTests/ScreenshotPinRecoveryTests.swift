import AppKit
import Testing
@testable import Typeflux

@Suite(.exclusiveUIState)
@MainActor
struct ScreenshotPinRecoveryTests {
    private func pin(_ controller: ScreenshotPinController, width: Int = 400) throws -> ScreenshotPinPanel {
        controller.pin(ScreenCaptureTestSupport.image(width: width, height: 200), scale: 1,
                       at: CGRect(x: 100, y: 100, width: width, height: 200)) { _ in }
        return try #require(controller.panels.last)
    }

    @Test(arguments: [40, 400])
    func `click through keeps restore and close controls clickable`(width: Int) throws {
        let controller = ScreenshotPinController()
        defer { controller.closeAll() }
        let panel = try pin(controller, width: width)
        let view = try #require(panel.contentView as? ScreenshotPinView)
        #expect(controller.recoveryPanel(for: panel) == nil)
        view.perform(.clickThrough)

        let recovery = try #require(controller.recoveryPanel(for: panel))
        let controls = try #require(recovery.contentView as? ScreenshotPinRecoveryView)
        #expect(panel.ignoresMouseEvents)
        #expect(recovery.isVisible)
        #expect(!recovery.ignoresMouseEvents)
        #expect(recovery.parent === panel)
        #expect(recovery.alphaValue == 1)
        let closePoint = CGPoint(x: controls.closeButton.frame.midX, y: controls.closeButton.frame.midY)
        #expect(controls.hitTest(closePoint) === controls.closeButton)
        #expect(controls.restoreButton.toolTip == L("menu.pins.restoreMouse"))

        controls.restoreButton.performClick(nil)
        #expect(!panel.ignoresMouseEvents)
        #expect(!view.state.clickThrough)
        #expect(controller.recoveryPanel(for: panel) == nil)
        #expect(!recovery.isVisible)
        #expect(recovery.parent == nil)

        view.perform(.clickThrough)
        let closeRecovery = try #require(controller.recoveryPanel(for: panel))
        let closeControls = try #require(closeRecovery.contentView as? ScreenshotPinRecoveryView)
        closeControls.closeButton.performClick(nil)
        #expect(controller.pinCount == 0)
        #expect(!panel.isVisible)
        #expect(!closeRecovery.isVisible)
        #expect(closeRecovery.contentView == nil)
    }

    @Test func `restoring one pin leaves the other pin in click through`() throws {
        let controller = ScreenshotPinController()
        defer { controller.closeAll() }
        let first = try pin(controller)
        let second = try pin(controller)
        for view in controller.views {
            view.perform(.clickThrough)
        }
        let recovery = try #require(controller.recoveryPanel(for: first))
        let controls = try #require(recovery.contentView as? ScreenshotPinRecoveryView)
        controls.restoreButton.performClick(nil)
        #expect(controller.pinCount == 2)
        #expect(controller.clickThroughCount == 1)
        #expect(second.ignoresMouseEvents)
        #expect(controller.recoveryPanel(for: second)?.isVisible == true)

        controller.restoreMouse()
        #expect(controller.clickThroughCount == 0)
        #expect(controller.recoveryPanel(for: second) == nil)
    }

    @Test func `recovery controls follow zoom and remain visible at low opacity`() throws {
        let controller = ScreenshotPinController()
        defer { controller.closeAll() }
        let panel = try pin(controller)
        let view = try #require(panel.contentView as? ScreenshotPinView)
        view.perform(.clickThrough)
        let recovery = try #require(controller.recoveryPanel(for: panel))
        view.state.zoom = 0.5
        view.state.opacity = 0.2
        #expect(controller.recoveryPanel(for: panel) === recovery)
        #expect(recovery.frame.midX == panel.frame.midX)
        #expect(recovery.frame.minY == panel.frame.minY + 8)
        #expect(recovery.alphaValue == 1)
        #expect(recovery.isVisible)

        controller.closeAll()
        #expect(controller.pinCount == 0)
        #expect(!recovery.isVisible)
        #expect(recovery.parent == nil)
        #expect(recovery.contentView == nil)
    }

    @Test(arguments: [ScreenshotOverlayView.Key.escape, ScreenshotOverlayView.Key.delete,
                      ScreenshotOverlayView.Key.forwardDelete])
    func `close keys work in the recovery controls`(keyCode: UInt16) throws {
        let controller = ScreenshotPinController()
        defer { controller.closeAll() }
        let panel = try pin(controller)
        let view = try #require(panel.contentView as? ScreenshotPinView)
        view.perform(.clickThrough)
        let recovery = try #require(controller.recoveryPanel(for: panel))
        let controls = try #require(recovery.contentView as? ScreenshotPinRecoveryView)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: recovery.windowNumber, context: nil,
                                                characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                                keyCode: keyCode))
        controls.keyDown(with: event)
        #expect(controller.pinCount == 0)
        #expect(!recovery.isVisible)
    }
}
