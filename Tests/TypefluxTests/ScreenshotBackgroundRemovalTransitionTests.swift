import AppKit
@testable import Typeflux
import XCTest

@MainActor
final class ScreenshotBackgroundRemovalTransitionTests: XCTestCase {
    private func alpha(_ progress: CGFloat) throws -> [UInt8] {
        let image = try XCTUnwrap(ScreenshotBackgroundDissolve.mask(width: 32, height: 24, progress: progress))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return stride(from: 3, to: data.count, by: 4).map { data[$0] }
    }

    func testDissolveStartsOpaqueEndsTransparentAndNeverReappears() throws {
        let start = try alpha(0)
        let middle = try alpha(0.5)
        let later = try alpha(0.8)
        let end = try alpha(1)
        XCTAssertTrue(start.allSatisfy { $0 == 255 })
        XCTAssertTrue(end.allSatisfy { $0 == 0 })
        XCTAssertTrue(middle.contains(0))
        XCTAssertTrue(middle.contains(255))
        XCTAssertTrue(middle.contains { $0 > 0 && $0 < 255 }, "Particles fade through soft edges")
        XCTAssertTrue(zip(middle, later).allSatisfy { $0 >= $1 })
        XCTAssertEqual(try alpha(0.5), middle, "Noise stays fixed instead of flickering between frames")
        XCTAssertEqual(try alpha(-1), start)
        XCTAssertEqual(try alpha(2), end)
        XCTAssertNil(ScreenshotBackgroundDissolve.mask(width: 0, height: 2, progress: 0))
    }

    private func hosted(reduced: Bool = false) -> (ScreenshotBackgroundRemovalTransition, NSWindow, CGImage) {
        _ = NSApplication.shared
        let view = ScreenshotBackgroundRemovalTransition()
        view.reducesMotion = { reduced }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        container.addSubview(view)
        window.contentView = container
        let image = ScreenCaptureTestSupport.image(width: 80, height: 60)
        return (view, window, image)
    }

    func testCompletionLeavesTheResultAvailableWithoutInterceptingInput() async {
        let (view, window, image) = hosted()
        defer { window.orderOut(nil) }
        let done = expectation(description: "Dissolve completes")
        view.onFinish = { done.fulfill() }
        view.show(image, original: image, in: CGRect(x: 10, y: 5, width: 60, height: 40))
        XCTAssertTrue(view.isTransitioning)
        XCTAssertFalse(view.isHidden)
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(view.isTransitioning)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(view.result === image)
    }

    func testRestoreInterruptsDissolveAndRetiresTheOldCompletion() async {
        let (view, window, image) = hosted()
        defer { window.orderOut(nil) }
        let restored = expectation(description: "Restored")
        var completions = 0
        view.onFinish = { completions += 1; restored.fulfill() }
        view.show(image, original: image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        view.restore()
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(view.result)
        XCTAssertFalse(view.isTransitioning)
        XCTAssertTrue(view.isHidden)
    }

    func testCancelClearsLayersWithoutReportingSuccess() async {
        let (view, window, image) = hosted()
        defer { window.orderOut(nil) }
        let finished = expectation(description: "Cancelled transition must not complete")
        finished.isInverted = true
        view.onFinish = { finished.fulfill() }
        view.show(image, original: image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        view.cancel()
        await fulfillment(of: [finished], timeout: 0.8)
        XCTAssertFalse(view.isTransitioning)
        XCTAssertNil(view.result)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(view.layer?.sublayers?.allSatisfy { $0.contents == nil } == true)
    }

    func testReducedMotionUsesShortFadeAndUnhostedViewsStayStatic() async {
        let (view, window, image) = hosted(reduced: true)
        defer { window.orderOut(nil) }
        let finished = expectation(description: "Reduced motion completes promptly")
        view.onFinish = { finished.fulfill() }
        view.show(image, original: image, in: CGRect(x: 0, y: 0, width: 80, height: 60))
        await fulfillment(of: [finished], timeout: 0.5)
        XCTAssertFalse(view.isTransitioning)
        let unhosted = ScreenshotBackgroundRemovalTransition()
        unhosted.show(image, original: image, in: .zero)
        XCTAssertFalse(unhosted.isTransitioning)
        XCTAssertTrue(unhosted.result === image)
        unhosted.restore()
        XCTAssertNil(unhosted.result)
    }
}
