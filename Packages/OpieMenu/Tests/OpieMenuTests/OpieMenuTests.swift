import AppKit
import XCTest
@testable import OpieMenu

final class OpieMenuTests: XCTestCase {
    @MainActor
    func testPointerHoverOnlyNotifiesWhenEnteringAnItem() {
        let items = (0..<4).map {
            OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star"))
        }
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620),
                                  items: items, centerTitle: "Ring")
        var hovered: [String] = []
        view.onHover = { hovered.append($0.id) }
        view.updateHover(at: NSPoint(x: 310, y: 310))
        XCTAssertTrue(hovered.isEmpty)
        view.updateHover(at: NSPoint(x: 310, y: 420))
        view.updateHover(at: NSPoint(x: 310, y: 430))
        XCTAssertEqual(hovered.count, 1)
        view.updateHover(at: NSPoint(x: 420, y: 310))
        XCTAssertEqual(hovered.count, 2)
        XCTAssertNotEqual(hovered[0], hovered[1])
        view.updateHover(at: NSPoint(x: 310, y: 310))
        XCTAssertEqual(hovered.count, 2)
        view.updateHover(at: NSPoint(x: 420, y: 310))
        XCTAssertEqual(hovered.count, 3)
        view.setPointerPreview(NSPoint(x: 310, y: 420))
        XCTAssertEqual(hovered.count, 3)
    }

    @MainActor
    func testCenterClickSwitchesInsteadOfClosingWhenHandled() {
        let items = (0..<4).map { OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star")) }
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620), items: items, centerTitle: "Ring")
        var closes = 0, clicks = 0, selections: [String] = []
        view.onClose = { closes += 1 }
        view.onSelect = { selections.append($0.id) }
        let middle = NSPoint(x: 310, y: 310)
        XCTAssertTrue(view.isInCenter(middle))
        XCTAssertFalse(view.isInCenter(NSPoint(x: 310, y: 420)))

        view.beginPointerPress(at: middle)
        view.releasePointerPress(at: middle)
        XCTAssertEqual(closes, 1, "without a handler the middle closes the ring")

        view.onCenterClick = { clicks += 1 }
        view.beginPointerPress(at: middle)
        view.releasePointerPress(at: middle)
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(closes, 1)
        view.beginPointerPress(at: NSPoint(x: 310, y: 420))
        view.releasePointerPress(at: NSPoint(x: 310, y: 420))
        XCTAssertEqual(selections, ["item-0"], "slices still run")
    }

    @MainActor
    func testEntireCenterCircleSwitchesWithoutSelectingOrClosing() {
        let items = (0..<4).map { OpieMenuItem(id: "item-\($0)", title: "Item \($0)", icon: .systemSymbol("star")) }
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620), items: items, centerTitle: "Ring")
        var clicks = 0
        view.onCenterClick = { clicks += 1 }
        view.onClose = { XCTFail("Center clicks must keep the menu open") }
        view.onSelect = { _ in XCTFail("Center clicks must not select an action") }
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        for radius in [CGFloat(0), 30, 47, 50, 53.9] {
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                let point = NSPoint(x: 310 + radius * cos(angle), y: 310 + radius * sin(angle))
                XCTAssertTrue(view.isInCenter(point))
                view.beginPointerPress(at: point)
                view.releasePointerPress(at: point)
            }
        }
        XCTAssertEqual(clicks, 80)
        XCTAssertFalse(view.isInCenter(NSPoint(x: 364, y: 310)), "The slice boundary belongs to actions")
        XCTAssertFalse(view.isInCenter(NSPoint(x: 360, y: 360)), "The hit area must stay circular")
        view.stopMotion()
    }

    @MainActor
    func testLiquidCenterBlankAreaHasClickReceivingAlpha() throws {
        _ = NSApplication.shared
        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620), items: [], centerTitle: "")
        view.style = .liquidGlass
        view.setMotionPreview(phase: "open", progress: 1)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Sample blank space away from the title, page dots and center rim.
        let x = Int(CGFloat(bitmap.pixelsWide) * 345 / 620)
        let y = bitmap.pixelsHigh / 2
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
    }

    @MainActor
    func testShowingAPageReplacesItemsAndCentreAndRendersEveryPhase() throws {
        _ = NSApplication.shared
        let first = (0..<3).map { OpieMenuItem(id: "a-\($0)", title: "A \($0)", icon: .systemSymbol("star")) }
        let second = (0..<5).map { OpieMenuItem(id: "b-\($0)", title: "B \($0)", icon: .systemSymbol("star")) }
        let menu = OpieRadialMenu(items: first, onSelect: { _ in })
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        menu.showPage(items: second, centerTitle: "A Very Long Application Name",
                      center: OpieMenuCenter(icon: icon, pageCount: 2, pageIndex: 0))
        XCTAssertEqual(menu.items.map(\.id), second.map(\.id))
        XCTAssertEqual(menu.centerTitle, "A Very Long Application Name")
        XCTAssertEqual(menu.center.pageCount, 2)
        XCTAssertEqual(OpieMenuCenter(pageCount: 0, pageIndex: 5).pageIndex, 0, "clamped")

        let view = RadialMenuView(frame: NSRect(x: 0, y: 0, width: 620, height: 620), items: second, centerTitle: "Go")
        let appIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calendar.app")
        for (index, center) in [OpieMenuCenter(icon: appIcon, pageCount: 2, pageIndex: 0),
                                OpieMenuCenter(pageCount: 2, pageIndex: 1), .plain].enumerated() {
            view.update(items: second, centerTitle: index == 0 ? "Calendar" : "Go", center: center)
            view.onCenterClick = {}
            view.updateHover(at: NSPoint(x: 310, y: 310))
            for progress in [0, 0.5, 1] as [CGFloat] {
                view.setMotionPreview(phase: "swap", progress: progress)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["OPIE_SNAPSHOTS"] {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("center-\(index)-\(Int(progress * 100)).png"))
                }
            }
        }
        view.animateSwap()
        view.stopMotion()
    }

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
