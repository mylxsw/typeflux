import AppKit
import SwiftUI

/// Native event tracking leaves the main actor free for recorder startup and
/// preserves the editor's insertion point while the button is pressed.
struct AskVoiceButton: NSViewRepresentable {
    @ObservedObject var voice: AskVoiceInput
    var contextID: String
    var compact: Bool
    var enabled: Bool
    var shortcut: HotkeyBinding?

    static func help(shortcut: HotkeyBinding?) -> String {
        let instructions = L("ask.voice.buttonHint")
        guard let shortcut else { return instructions }
        return instructions + "\n" + L("ask.voice.shortcutHint", HotkeyFormat.display(shortcut))
    }

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.identifier = NSUserInterfaceItemIdentifier("ask.voice.button")
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.refusesFirstResponder = true
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.target = button
        button.action = #selector(Control.activate)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        button.voice = voice
        button.contextID = contextID
        let listening = voice.context == contextID && voice.phase == .listening
        let transcribing = voice.context == contextID && voice.phase == .transcribing
        let title = L(listening ? "ask.voice.stop" : transcribing ? "ask.voice.transcribing" : "ask.voice.input")
        button.title = compact ? "" : title
        button.image = NSImage(systemSymbolName: listening ? "stop.fill" : "mic.fill", accessibilityDescription: nil)
        button.imagePosition = compact ? .imageOnly : .imageLeading
        button.contentTintColor = listening ? .controlAccentColor : .labelColor
        button.isEnabled = enabled && (!voice.isOccupied || listening)
        button.toolTip = listening ? L("ask.voice.stopHint") : transcribing ? title : Self.help(shortcut: shortcut)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(button.toolTip)
    }

    final class Control: NSButton {
        weak var voice: AskVoiceInput?
        var contextID = ""
        private var localReleaseMonitor: Any?
        private var globalReleaseMonitor: Any?

        private func destination(in view: NSView) -> AskComposerTextView.Editor? {
            if let editor = view as? AskComposerTextView.Editor,
               editor.contextID == contextID, editor.voice === voice { return editor }
            return view.subviews.lazy.compactMap { self.destination(in: $0) }.first
        }

        private func press(at timestamp: TimeInterval) -> Bool {
            guard isEnabled, let voice, let window, let content = window.contentView,
                  let editor = destination(in: content) else { return false }
            window.makeKey()
            guard window.makeFirstResponder(editor) else { return false }
            return voice.pressButton(in: editor, at: timestamp)
        }

        @objc func activate() {
            let now = ProcessInfo.processInfo.systemUptime
            if press(at: now) { voice?.releaseButton(inside: true, at: now) }
        }

        override func mouseDown(with event: NSEvent) {
            clearTracking()
            guard press(at: event.timestamp) else { return }
            highlight(true)
            // The release may arrive outside this control or outside the app.
            localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.finish(with: event)
                return nil
            }
            globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.finish(with: event, outside: true)
            }
        }

        override func mouseUp(with event: NSEvent) { finish(with: event) }

        private func finish(with event: NSEvent, outside: Bool = false) {
            let inside = !outside && event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            voice?.releaseButton(inside: inside, at: event.timestamp)
            clearTracking()
        }

        private func clearTracking() {
            highlight(false)
            if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor); self.localReleaseMonitor = nil }
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor); self.globalReleaseMonitor = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                if localReleaseMonitor != nil, voice?.context == contextID { voice?.cancel() }
                clearTracking()
            }
        }

        deinit {
            if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor) }
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor) }
        }
    }
}
