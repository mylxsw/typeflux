import AppKit
import XCTest
@testable import OpieMenu

final class RingDismissalTests: XCTestCase {
    @MainActor
    private func makeMenu(onSelect: @escaping (OpieMenuItem) -> Void = { _ in }) -> OpieRadialMenu {
        _ = NSApplication.shared
        return OpieRadialMenu(items: (0..<3).map {
            OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star"))
        }, onSelect: onSelect)
    }

    @MainActor
    func testCancellationIsSynchronousEvenWithHighlightedItemAndCanReopen() async throws {
        var selections = 0
        let menu = makeMenu { _ in selections += 1 }
        var dismissals = 0
        var completions = 0
        menu.onDismiss = { dismissals += 1 }
        menu.show(takesKeyboardFocus: false)
        menu.select(index: 1)
        menu.dismiss { completions += 1 }
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(selections, 0)

        menu.show(takesKeyboardFocus: false)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(menu.isVisible, "An earlier close must not hide the reopened ring")
        XCTAssertEqual(dismissals, 1)
        menu.dismiss()
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(dismissals, 2)
        menu.dismiss { completions += 1 }
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(dismissals, 2)
    }

    @MainActor
    func testConfirmedActionWaitsForRotationAndRunsOnce() async throws {
        var events: [String] = []
        let menu = makeMenu { events.append($0.id) }
        menu.onDismiss = { events.append("dismiss") }
        menu.show(takesKeyboardFocus: false)
        let surface = try XCTUnwrap(menu.preparedWindow?.contentView as? RadialMenuSurface)
        surface.radialMenu.freezesPointerForPreview = true
        try await Task.sleep(for: .milliseconds(350))
        menu.select(index: 1)
        menu.activateSelection()
        XCTAssertTrue(menu.isVisible)
        XCTAssertTrue(events.isEmpty)
        menu.activateSelection()
        menu.dismiss()
        try await Task.sleep(for: .milliseconds(180))
        let motion = surface.radialMenu.motionSnapshot
        XCTAssertLessThan(motion.rotation, -0.1)
        XCTAssertGreaterThan(motion.scale, 1)
        XCTAssertLessThan(motion.opacity, 1)
        for _ in 0..<200 where menu.isVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(events, ["dismiss", "item-1"])
    }

    @MainActor
    func testReferenceClosingMotionRotatesEnlargesAndFades() {
        let menu = makeMenu()
        menu.prepare()
        let view = (menu.preparedWindow!.contentView as! RadialMenuSurface).radialMenu
        view.setMotionPreview(phase: "close", progress: 0)
        let start = view.motionSnapshot
        view.setMotionPreview(phase: "close", progress: 0.4)
        let middle = view.motionSnapshot
        view.setMotionPreview(phase: "close", progress: 1)
        let end = view.motionSnapshot
        XCTAssertEqual(start.rotation, 0)
        XCTAssertEqual(start.opacity, 1)
        XCTAssertLessThan(middle.rotation, start.rotation)
        XCTAssertGreaterThan(middle.scale, start.scale)
        XCTAssertGreaterThan(middle.opacity, 0)
        XCTAssertLessThan(middle.opacity, start.opacity)
        XCTAssertLessThan(middle.centerOpacity, middle.opacity)
        XCTAssertLessThan(end.rotation, middle.rotation)
        XCTAssertEqual(end.rotation, -1.60, accuracy: 0.001)
        XCTAssertEqual(end.opacity, 0)
        XCTAssertEqual(end.symbolOpacity, 0)
    }

    @MainActor
    func testClosingFadesEntireSurfaceInStepWithRotationForEveryStyle() throws {
        for style in [OpieMenuStyle.classic, .frosted, .liquidGlass] where style.isAvailable {
            let menu = makeMenu()
            menu.setStyle(style)
            menu.prepare()
            let surface = try XCTUnwrap(menu.preparedWindow?.contentView as? RadialMenuSurface)
            let view = surface.radialMenu
            var lastOpacity: CGFloat = 1
            var lastRotation: CGFloat = 0
            for progress: CGFloat in [0.05, 0.2, 0.4, 0.6, 0.8, 0.95, 1] {
                view.setMotionPreview(phase: "close", progress: progress)
                let motion = view.motionSnapshot
                XCTAssertLessThan(motion.opacity, lastOpacity)
                XCTAssertLessThan(motion.rotation, lastRotation)
                XCTAssertEqual(motion.opacity, 1 - motion.rotation / -1.60, accuracy: 0.001)
                XCTAssertEqual(surface.alphaValue, motion.opacity, accuracy: 0.001)
                XCTAssertEqual(motion.symbolOpacity, motion.opacity, accuracy: 0.001)
                // Material stays at its original opacity inside the fading parent;
                // applying the fade twice would make content vanish before the glass.
                XCTAssertEqual(view.glassShape.opacity, 1)
                XCTAssertTrue(surface.subviews.allSatisfy { $0.alphaValue == 1 })
                lastOpacity = motion.opacity
                lastRotation = motion.rotation
            }
            XCTAssertEqual(surface.alphaValue, 0)
            view.prepareForOpening()
            view.animateIn()
            surface.updateGlassShape()
            XCTAssertEqual(surface.alphaValue, 1, "Reopening must clear the completed group fade")
            view.stopMotion()
        }
    }

    @MainActor
    func testClosingDuringOpeningPreservesContentOpacityInsideGroup() throws {
        let menu = makeMenu()
        menu.prepare()
        let surface = try XCTUnwrap(menu.preparedWindow?.contentView as? RadialMenuSurface)
        let view = surface.radialMenu
        view.setMotionPreview(phase: "open", progress: 0.25)
        let opening = view.motionSnapshot
        view.animateOut {}
        defer { view.stopMotion() }
        view.setMotionPreview(phase: "close", progress: 0)
        XCTAssertEqual(view.motionSnapshot.opacity, opening.opacity)
        XCTAssertEqual(view.motionSnapshot.symbolOpacity, opening.symbolOpacity)
        view.setMotionPreview(phase: "close", progress: 0.5)
        XCTAssertEqual(view.motionSnapshot.opacity, opening.opacity * surface.alphaValue, accuracy: 0.001)
        XCTAssertEqual(view.motionSnapshot.symbolOpacity, opening.symbolOpacity * surface.alphaValue, accuracy: 0.001)
    }

    @MainActor
    func testStoppingMotionDiscardsPendingCloseCallback() async throws {
        let menu = makeMenu()
        menu.prepare()
        let view = (menu.preparedWindow!.contentView as! RadialMenuSurface).radialMenu
        var closed = false
        view.animateOut { closed = true }
        view.stopMotion()
        view.animateIn()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(closed)
        XCTAssertEqual(view.motionSnapshot.opacity, 1)
        view.stopMotion()
    }
}
