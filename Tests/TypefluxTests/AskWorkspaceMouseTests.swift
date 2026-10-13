import AppKit
import Testing

@MainActor
@Suite(.serialized, .exclusiveUIState)
struct AskWorkspaceMouseTests {
    @Test func queuedReleaseCompletesNativeButtonTrackingExactlyOnce() throws {
        let recorder = ActionRecorder()
        let button = NSButton(title: "Native action", target: recorder, action: #selector(ActionRecorder.press))
        try withWindow(button) { window in
            for expected in 1 ... 2 {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                try AskWorkspaceTestMouse.click(at: point, in: window)
                #expect(recorder.calls == expected)
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

    private func withWindow(_ view: NSView, check: (NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
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

    @MainActor private final class NontrackingView: NSView {
        var presses = 0
        var releases = 0
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
        override func mouseDown(with _: NSEvent) { presses += 1 }
        override func mouseUp(with _: NSEvent) { releases += 1 }
    }
}
