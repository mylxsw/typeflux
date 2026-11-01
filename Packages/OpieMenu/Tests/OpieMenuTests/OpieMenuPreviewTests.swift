import AppKit
import XCTest
@testable import OpieMenu

final class OpieMenuPreviewTests: XCTestCase {
    @MainActor
    func testEmbeddedSurfaceUsesTheLiveRendererAndUpdatesConfiguration() throws {
        _ = NSApplication.shared
        let initial = OpieMenuItem(id: "first", title: "First", icon: .systemSymbol("star"))
        let preview = OpieMenuPreviewView(items: [initial], centerTitle: "My ring", style: .classic)
        defer { preview.stop() }
        let surface = try XCTUnwrap(preview.subviews.first as? RadialMenuSurface)
        XCTAssertTrue(surface.radialMenu === preview.radialMenu)
        XCTAssertFalse(preview.radialMenu.tracksPointerOutsideBounds)
        XCTAssertEqual(preview.radialMenu.style, .classic)
        preview.configure(items: [.init(id: "new", title: "New action", icon: .systemSymbol("heart"))],
                          centerTitle: "Updated", style: .frosted)
        XCTAssertEqual(preview.radialMenu.items.map(\.id), ["new"])
        XCTAssertEqual(preview.radialMenu.centerTitle, "Updated")
        XCTAssertEqual(preview.radialMenu.style, .frosted)
        XCTAssertTrue(surface.glassIsVisible)
    }

    @MainActor
    func testPracticeSelectionOnlyCallsTheHostAndStopsOnExit() throws {
        _ = NSApplication.shared
        let preview = OpieMenuPreviewView(items: [.init(id: "action", title: "Action", icon: .systemSymbol("star"))],
                                          centerTitle: "Ring", style: .classic)
        defer { preview.stop() }
        var selected: [String] = []
        preview.onSelect = { selected.append($0.id) }
        let menu = preview.radialMenu
        let point = NSPoint(x: menu.bounds.midX, y: menu.bounds.midY + 100)
        menu.beginPointerPress(at: point)
        menu.releasePointerPress(at: point)
        XCTAssertEqual(selected, ["action"])
        menu.updateHover(at: point)
        let exit = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   eventNumber: 0, clickCount: 0, pressure: 0))
        menu.mouseExited(with: exit)
        XCTAssertFalse(menu.activatePointerSelection(), "Leaving an embedded preview clears the target")
        XCTAssertEqual(selected, ["action"])
        preview.stop()
        menu.beginPointerPress(at: point)
        menu.releasePointerPress(at: point)
        XCTAssertEqual(selected, ["action"], "A detached preview must discard callbacks")
    }

    @MainActor
    func testResizingKeepsTheMaterialAlignedWithTheRing() throws {
        _ = NSApplication.shared
        let preview = OpieMenuPreviewView(items: [], centerTitle: "Ring", style: .frosted)
        defer { preview.stop() }
        preview.setFrameSize(NSSize(width: 520, height: 440))
        preview.needsLayout = true
        preview.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(preview.subviews.first as? RadialMenuSurface)
        XCTAssertEqual(surface.glassMaskBounds.midX, 260, accuracy: 1)
        XCTAssertEqual(surface.glassMaskBounds.midY, 220, accuracy: 1)
    }
}
