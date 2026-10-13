import AppKit
import Testing

extension TypefluxNavigationTestSupport {
    static func focus(_ view: NSView, in window: NSWindow) throws {
        _ = try #require(view.window === window, "The responder must belong to the owned panel")
        _ = try #require(window.makeFirstResponder(view), "The panel must accept the target responder")
        // Swift Testing pumps CFRunLoopRun rather than NSApp.run. A field can be
        // first responder before WindowServer has established its field editor.
        if let field = view as? NSTextField, let editor = field.currentEditor() {
            #expect(window.firstResponder === editor)
        } else {
            #expect(window.firstResponder === view)
        }
    }

    static func changeText(_ text: String, in field: NSTextField) throws {
        let delegate = try #require(field.delegate)
        if let editor = field.currentEditor() as? NSTextView { editor.string = text }
        field.stringValue = text
        // Exercise the rendered control's binding without waiting for a key-window event.
        delegate.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    static func wait(_ description: String, in window: NSWindow, host: NSView,
                     diagnostics: () -> String = { "" }, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                let field = searchField(in: host)
                let responder = window.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
                let detail = "visible=\(window.isVisible), responder=\(responder), "
                    + "searchField=\(field != nil), fieldEditor=\(field?.currentEditor() != nil), "
                    + "fieldQuery=\(field?.stringValue.debugDescription ?? "nil"). \(diagnostics())"
                Issue.record("Timed out waiting for \(description): \(detail)")
                throw FocusReadinessTimeout(description: description)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private struct FocusReadinessTimeout: Error, CustomStringConvertible {
    let description: String
}
