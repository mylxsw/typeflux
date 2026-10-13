import AppKit
import Testing

/// Deliver to the owned window; native controls use target/action instead of mouse tracking.
@MainActor
enum AskWorkspaceTestMouse {
    static func click(at point: NSPoint, in window: NSWindow) throws {
        let root = try #require(window.contentView?.superview ?? window.contentView)
        let local = root.superview?.convert(point, from: nil) ?? root.convert(point, from: nil)
        var target: NSView? = try #require(root.hitTest(local), "No view at click location \(point)")
        while let view = target {
            if let matrix = view as? NSMatrix {
                let local = matrix.convert(point, from: nil)
                for row in 0 ..< matrix.numberOfRows {
                    for column in 0 ..< matrix.numberOfColumns
                        where matrix.cellFrame(atRow: row, column: column).contains(local) {
                        try AppKitTestActions.selectCell(#require(matrix.cell(atRow: row, column: column)), in: matrix)
                        return
                    }
                }
                try #require(false, "Missing native matrix cell at click location")
                return
            }
            if let control = view as? NSSegmentedControl {
                guard control.isEnabled else { return }
                let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
                let segment = try #require(SettingsBehaviorTestSupport.elements(in: control).first {
                    $0.object !== control && $0.frame.contains(screenPoint)
                        && [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.radioButton.rawValue]
                            .contains($0.role)
                }, "Missing native segment at click location")
                let index = try #require((0 ..< control.segmentCount).first {
                    control.label(forSegment: $0) == segment.label || control.toolTip(forSegment: $0) == segment.label
                })
                control.selectedSegment = index
                try AppKitTestActions.dispatch(control)
                return
            }
            if let control = view as? NSButton {
                try AppKitTestActions.press(control)
                return
            }
            if let control = view as? NSSwitch {
                try AppKitTestActions.press(control)
                return
            }
            target = view.superview
        }
        let press = try event(.leftMouseDown, at: point, in: window)
        let release = try event(.leftMouseUp, at: point, in: window)
        window.sendEvent(press)
        window.sendEvent(release)
    }

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
}
