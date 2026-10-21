import AppKit
import XCTest
@testable import OpieMenu

final class OpieMenuTests: XCTestCase {
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
