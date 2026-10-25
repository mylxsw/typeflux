import AppKit
import XCTest
@testable import OpieMenu

final class OpieMenuTests: XCTestCase {
    @MainActor
    func testNumberKeysMatchDisplayedPositions() {
        for (index, code) in [UInt16(18), 19, 20, 21, 23, 22, 26, 28].enumerated() {
            XCTAssertEqual(OpieRadialMenu.numberedItemIndex(keyCode: code), index)
        }
        XCTAssertNil(OpieRadialMenu.numberedItemIndex(keyCode: 25))
        XCTAssertNil(OpieRadialMenu.numberedItemIndex(keyCode: 53))
    }

    @MainActor
    func testPreparingAndReopeningReusesWindowSurfaceAndCurrentConfiguration() async throws {
        _ = NSApplication.shared
        let items = (0..<3).map { OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star")) }
        var selections = 0
        let menu = OpieRadialMenu(items: items, onSelect: { _ in selections += 1 })
        menu.prepare()
        let window = try XCTUnwrap(menu.preparedWindow)
        let surface = try XCTUnwrap(window.contentView as? RadialMenuSurface)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(window.animationBehavior, .none)
        menu.focusKeyboard()
        menu.moveSelection(1)
        menu.select(index: 0)
        menu.activateSelection()
        XCTAssertFalse(menu.activatePointedItem())
        XCTAssertEqual(selections, 0)
        XCTAssertFalse(window.isVisible)
        menu.prepare()
        XCTAssertTrue(menu.preparedWindow === window)
        menu.show(at: NSPoint(x: 400, y: 400), takesKeyboardFocus: false)
        XCTAssertTrue(menu.isVisible)
        XCTAssertFalse(menu.hasKeyboardFocus)
        var dismissed = 0
        menu.onDismiss = { dismissed += 1 }
        menu.dismiss()
        for _ in 0..<200 where menu.isVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(dismissed, 1)
        XCTAssertTrue(menu.preparedWindow === window)
        menu.select(index: 0)
        menu.activateSelection()
        XCTAssertFalse(menu.activatePointedItem())
        XCTAssertEqual(selections, 0)
        menu.setCenterTitle("Updated")
        menu.updateItems(Array(items.prefix(2)))
        menu.setStyle(.classic)
        menu.show(at: NSPoint(x: 500, y: 500), takesKeyboardFocus: false)
        XCTAssertTrue(menu.preparedWindow === window)
        XCTAssertTrue(window.contentView === surface)
        XCTAssertEqual(surface.radialMenu.items.count, 2)
        XCTAssertEqual(surface.radialMenu.centerTitle, "Updated")
        XCTAssertEqual(surface.radialMenu.style, .classic)
        menu.updateItems([])
        for _ in 0..<200 where menu.isVisible { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(menu.isVisible)
        XCTAssertEqual(dismissed, 2)
    }

    @MainActor
    func testPreparedMenuExecutesOneSelectionAfterItsClosingAnimation() async throws {
        _ = NSApplication.shared
        let items = (0..<3).map { OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star")) }
        var selected: [String] = []
        let menu = OpieRadialMenu(items: items) { selected.append($0.id) }
        menu.prepare()
        menu.moveSelection(1)
        menu.show(at: NSEvent.mouseLocation, takesKeyboardFocus: false)
        menu.moveSelection(1)
        menu.select(index: 0)
        menu.activateSelection()
        menu.activateSelection()
        for _ in 0..<200 where selected.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(selected, [items[0].id])
        XCTAssertFalse(menu.isVisible)
    }

    func testCustomItemCountsAndSelection() async {
        let works = await MainActor.run {
            for count in [3, 7, 8] {
                let items = (0..<count).map {
                    OpieMenuItem(id: "action-\($0)", title: "Action \($0)", icon: .systemSymbol("star"))
                }
                let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620),
                                          items: items, centerTitle: "Tools")
                var chosen: [String] = []
                view.onSelect = { chosen.append($0.id) }
                for index in items.indices {
                    let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(count)
                    view.setPointerPreview(NSPoint(x: 310 + 180 * cos(angle), y: 310 + 180 * sin(angle)))
                    guard view.activatePointerSelection() else { return false }
                }
                guard chosen == items.map(\.id) else { return false }
                view.select(index: count - 1)
                view.activateSelection()
                guard chosen.last == items.last?.id else { return false }
            }
            return true
        }
        XCTAssertTrue(works)
    }

    func testGlassOutlineAndFastReleaseRecoil() async {
        let works = await MainActor.run {
            let items = (0..<7).map {
                OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star"))
            }
            let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620),
                                      items: items, centerTitle: "Menu")
            view.style = OpieMenuStyle.liquidGlass.isAvailable ? .liquidGlass : .frosted
            let surface = RadialMenuSurface(frame: view.frame, menu: view)
            let circleWidth = surface.glassMaskBounds.width
            let path = view.glassShape.path
            guard !path.contains(CGPoint(x: 310, y: 310), using: .winding),
                  path.contains(CGPoint(x: 310, y: 410), using: .winding) else { return false }
            if view.style == .liquidGlass {
                let center = view.centerGlassShape
                guard center.path.contains(CGPoint(x: 310, y: 310)),
                      !center.path.contains(CGPoint(x: 362, y: 310)),
                      center.opacity == 1 else { return false }
            }
            view.setPointerPreview(NSPoint(x: -500, y: 310))
            for _ in 0..<18 { view.stepJellyPreview(dt: 1.0 / 60.0) }
            let pulled = view.jellySnapshot.extent
            guard pulled > 45, surface.glassMaskBounds.width > circleWidth + 40 else { return false }
            view.setPointerPreview(nil)
            var smallest = CGFloat.infinity
            var afterFive = CGFloat.infinity
            for frame in 0..<30 {
                view.stepJellyPreview(dt: 1.0 / 60.0)
                if frame == 4 { afterFive = view.jellySnapshot.extent }
                smallest = min(smallest, view.jellySnapshot.extent)
            }
            return afterFive < pulled * 0.20 && smallest < -1 && abs(view.jellySnapshot.extent) < 1.5
        }
        XCTAssertTrue(works)
    }

    func testControllerConfigurationCanBeUpdated() async {
        let works = await MainActor.run {
            let initial = (0..<3).map {
                OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star"))
            }
            let menu = OpieRadialMenu(items: initial, centerTitle: "First", onSelect: { _ in })
            menu.prepare()
            menu.setCenterTitle("Second")
            menu.updateItems(initial + [OpieMenuItem(id: "extra", title: "Extra", icon: .smile)])
            menu.setStyle(.frosted)
            let configured = menu.items.count == 4 && menu.centerTitle == "Second" && menu.style == .frosted
            menu.updateItems([])
            menu.show()
            return configured && !menu.isVisible
        }
        XCTAssertTrue(works)
    }
}
