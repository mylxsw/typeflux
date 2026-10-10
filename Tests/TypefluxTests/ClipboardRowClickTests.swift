import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@MainActor
@Suite(.exclusiveUIState)
struct ClipboardRowClickTests {
    @Test func mouseDownSelectsImmediatelyAndSecondClickPastesOnce() throws {
        try withPanel { model, window, controls in
            var pasted: [String] = []
            model.onAction = { action, entry in
                if action == .paste { pasted.append(entry.id) }
            }
            let firstResponder = window.firstResponder
            let start = ProcessInfo.processInfo.systemUptime
            try send(.leftMouseDown, clicks: 1, row: controls[1], window: window, controls: controls)
            // No mouse-up, timer or run-loop wait: selection must already be updated.
            #expect(model.selectedIndex == 1)
            #expect(ProcessInfo.processInfo.systemUptime - start < NSEvent.doubleClickInterval)
            #expect(pasted.isEmpty)
            #expect(window.firstResponder === firstResponder)
            try send(.leftMouseUp, clicks: 1, row: controls[1], window: window, controls: controls)
            #expect(pasted.isEmpty)
            try send(.leftMouseDown, clicks: 2, row: controls[1], window: window, controls: controls)
            try send(.leftMouseUp, clicks: 2, row: controls[1], window: window, controls: controls)
            #expect(pasted == [model.visibleEntries[1].id])
            try send(.leftMouseDown, clicks: 3, row: controls[1], window: window, controls: controls)
            #expect(pasted.count == 1)
        }
    }

    @Test func singleClickPasteDoesNotPasteAgainOnSecondClick() throws {
        try withPanel { model, window, controls in
            model.singleClickPastes = true
            var pastes = 0
            model.onAction = { action, _ in if action == .paste { pastes += 1 } }
            try send(.leftMouseDown, clicks: 1, row: controls[1], window: window, controls: controls)
            #expect(model.selectedIndex == 1)
            #expect(pastes == 1)
            try send(.leftMouseUp, clicks: 1, row: controls[1], window: window, controls: controls)
            try send(.leftMouseDown, clicks: 2, row: controls[1], window: window, controls: controls)
            #expect(pastes == 1)
        }
    }

    @Test func contextClicksAndScrollPassThroughAndDisabledRowsIgnoreClicks() throws {
        try withPanel { model, window, controls in
            let control = controls[1]
            let point = control.convert(NSPoint(x: 20, y: control.bounds.midY), to: control.superview)
            for (type, flags) in [
                (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()),
                (.leftMouseDown, .control), (.leftMouseUp, .control)
            ] {
                let event = try event(type, clicks: 1, row: control, window: window, flags: flags)
                control.currentEvent = { event }
                #expect(control.hitTest(point) == nil)
            }
            let scrollEvent = try #require(CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0
            ))
            let scroll = try #require(NSEvent(cgEvent: scrollEvent))
            control.currentEvent = { scroll }
            #expect(control.hitTest(point) == nil)
            control.currentEvent = { nil }
            #expect(control.hitTest(point) == nil)
            let down = try event(.leftMouseDown, clicks: 1, row: control, window: window)
            control.currentEvent = { down }
            #expect(control.hitTest(point) === control)
            #expect(control.hitTest(NSPoint(x: -100, y: -100)) == nil)
            control.enabled = false
            #expect(control.hitTest(point) == nil)
            control.mouseDown(with: down)
            #expect(model.selectedIndex == 0)
            #expect(!control.acceptsFirstResponder)
            #expect(control.acceptsFirstMouse(for: down))
            #expect(!control.mouseDownCanMoveWindow)
        }
    }

    private func withPanel(
        _ body: (ClipboardPanelModel, NSWindow, [ClipboardRowClickArea.Control]) throws -> Void
    ) throws {
        let model = ClipboardPanelModel()
        model.reset(entries: [
            ClipboardTestSupport.entry(.text, text: "First"),
            ClipboardTestSupport.entry(.text, text: "Second")
        ])
        let size = ClipboardPanelView.size(showsPreview: false)
        let window = ClipboardPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: ClipboardPanelView(model: model, focusRequest: 0))
        root.frame = NSRect(origin: .zero, size: size)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        root.layoutSubtreeIfNeeded()
        func collect(_ view: NSView) -> [ClipboardRowClickArea.Control] {
            if let control = view as? ClipboardRowClickArea.Control { return [control] }
            return view.subviews.flatMap(collect)
        }
        let controls = collect(root).sorted {
            let first = $0.convert($0.bounds, to: root), second = $1.convert($1.bounds, to: root)
            return root.isFlipped ? first.minY < second.minY : first.maxY > second.maxY
        }
        #expect(controls.count == 2)
        guard controls.count == 2 else { return }
        try body(model, window, controls)
    }

    private func event(_ type: NSEvent.EventType, clicks: Int, row: NSView, window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: row.convert(NSPoint(x: 20, y: row.bounds.midY), to: nil),
            modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
        ))
    }

    private func send(_ type: NSEvent.EventType, clicks: Int, row: NSView, window: NSWindow,
                      controls: [ClipboardRowClickArea.Control]) throws {
        let event = try event(type, clicks: clicks, row: row, window: window)
        let previous = controls.map(\.currentEvent)
        defer { for (control, read) in zip(controls, previous) { control.currentEvent = read } }
        for control in controls { control.currentEvent = { event } }
        NSApp.sendEvent(event)
    }
}
