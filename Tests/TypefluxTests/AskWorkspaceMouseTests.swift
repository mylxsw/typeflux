import AppKit
import Testing

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceMouseTests {
    @Test func nativeButtonDispatchesExactlyOnceWithoutMouseTracking() throws {
        let recorder = ActionRecorder()
        let button = NontrackingButton(title: "Native action", target: recorder,
                                       action: #selector(ActionRecorder.press))
        try withWindow(button) { window in
            for expected in 1 ... 2 {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                try AskWorkspaceTestMouse.click(at: point, in: window)
                #expect(recorder.calls == expected)
                #expect(button.presses == 0)
                #expect(button.releases == 0)
            }
        }
    }

    @Test func nontrackingViewsReceiveEachPressAndReleaseExactlyOnce() throws {
        let view = NontrackingView()
        try withWindow(view) { window in
            for expected in 1 ... 2 {
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                try AskWorkspaceTestMouse.click(at: point, in: window)
                #expect(view.presses == expected)
                #expect(view.releases == expected)
            }
        }
    }

    @Test func nativeSegmentsSelectTheirHitTargetWithoutTracking() throws {
        let accessibility = AskWorkspaceTestAccessibility()
        defer { accessibility.restore() }
        let recorder = ActionRecorder()
        let control = NontrackingSegments(labels: ["First", "Second"], trackingMode: .selectOne,
                                          target: recorder, action: #selector(ActionRecorder.press))
        try withWindow(control) { window in
            let element = try #require(SettingsBehaviorTestSupport.elements(in: control).first { $0.label == "Second" })
            let frame = window.convertFromScreen(element.frame)
            try AskWorkspaceTestMouse.click(at: NSPoint(x: frame.midX, y: frame.midY), in: window)
            #expect(control.selectedSegment == 1)
            #expect(recorder.calls == 1)
            #expect(control.presses == 0)
        }
    }

    private func withWindow(_ view: NSView, check: (NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()
        try check(window)
    }

    @MainActor private final class ActionRecorder: NSObject {
        var calls = 0
        @objc func press() { calls += 1 }
    }

    @MainActor private final class NontrackingButton: NSButton {
        var presses = 0
        var releases = 0
        override func mouseDown(with _: NSEvent) { presses += 1 }
        override func mouseUp(with _: NSEvent) { releases += 1 }
    }

    @MainActor private final class NontrackingSegments: NSSegmentedControl {
        var presses = 0
        override func mouseDown(with _: NSEvent) { presses += 1 }
    }

    @MainActor private final class NontrackingView: NSView {
        var presses = 0
        var releases = 0
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
        override func mouseDown(with _: NSEvent) { presses += 1 }
        override func mouseUp(with _: NSEvent) { releases += 1 }
    }
}
