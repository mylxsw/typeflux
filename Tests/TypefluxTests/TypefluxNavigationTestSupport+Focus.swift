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

    static func sendAction(_ element: SettingsBehaviorTestSupport.Element) throws {
        let cellControl = (element.object as? NSCell)?.controlView as? NSControl
        let control = (element.object as? NSControl) ?? cellControl
            ?? element.window?.contentView.flatMap { host in
                descendants(of: host).compactMap { $0 as? NSButton }.first {
                    let frame = $0.window?.convertToScreen($0.convert($0.bounds, to: nil)) ?? .zero
                    return frame.intersects(element.frame) && ($0.title == element.label
                        || $0.accessibilityLabel() == element.label)
                }
            }
        let sender = try #require(control, "Missing native action sender for \(element.label)")
        _ = try #require(sender.isEnabled)
        let action = try #require(sender.action)
        #expect(NSApp.sendAction(action, to: sender.target, from: sender))
    }

    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
