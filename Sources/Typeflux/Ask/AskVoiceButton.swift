import AppKit
import SwiftUI

/// Native event tracking leaves the main actor free for recorder startup and
/// preserves the editor's insertion point while the button is pressed.
struct AskVoiceButton: NSViewRepresentable {
    @ObservedObject var voice: AskVoiceInput
    var contextID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.refusesFirstResponder = true
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
        button.title = ""
        button.visualPhase = voice.context == contextID ? voice.phase : .idle
        button.reduceMotion = reduceMotion
        button.isEnabled = enabled && (!voice.isOccupied || listening)
        button.toolTip = listening ? L("ask.voice.stopHint") : transcribing ? title : Self.help(shortcut: shortcut)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(button.toolTip)
        button.refreshAppearance()
    }

    struct Appearance: View {
        var phase: AskVoiceInput.Phase = .idle
        var enabled = true
        var hovered = false
        var pressed = false
        var reduceMotion = false

        private var accented: Bool { phase == .listening || (enabled && hovered) }

        static func fill(phase: AskVoiceInput.Phase, hovered: Bool) -> Color {
            if phase == .listening { return AskTheme.accent.opacity(0.22) }
            return hovered ? AskTheme.hoverFill : .clear
        }

        var body: some View {
            ZStack {
                if phase == .transcribing {
                    Circle().stroke(AskTheme.border, lineWidth: 1.5).frame(width: 16, height: 16)
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        Circle().trim(from: 0, to: 0.7)
                            .stroke(AskTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .frame(width: 16, height: 16)
                            .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) * 400))
                    }
                } else {
                    // Borderless like the other footer controls; colour only for hover and recording.
                    Circle().fill(Self.fill(phase: phase, hovered: enabled && hovered))
                    if phase == .listening {
                        RoundedRectangle(cornerRadius: 2).fill(AskTheme.accent).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "mic").font(.system(size: 15, weight: .regular))
                            .foregroundStyle(accented ? StudioTheme.textPrimary : StudioTheme.textSecondary)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .opacity(enabled || phase == .transcribing ? 1 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            .accessibilityHidden(true)
        }
    }

    /// The native control owns events and accessibility; its SwiftUI child only draws.
    final class Artwork: NSHostingView<Appearance> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Control: NSButton {
        weak var voice: AskVoiceInput?
        var contextID = ""
        private var localReleaseMonitor: Any?
        private var globalReleaseMonitor: Any?

        var visualPhase: AskVoiceInput.Phase = .idle
        var reduceMotion = false
        private(set) var hovered = false
        private var hoverTracking: NSTrackingArea?
        private var artwork: Artwork?

        override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
        override func draw(_ dirtyRect: NSRect) {} // The artwork replaces NSButton's bezel.

        func refreshAppearance() {
            let appearance = Appearance(phase: visualPhase, enabled: isEnabled, hovered: hovered,
                                        pressed: isHighlighted, reduceMotion: reduceMotion)
            if let artwork {
                artwork.rootView = appearance
            } else {
                let view = Artwork(rootView: appearance)
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                view.setAccessibilityElement(false)
                addSubview(view)
                artwork = view
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTracking { removeTrackingArea(hoverTracking) }
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(tracking)
            hoverTracking = tracking
        }

        override func mouseEntered(with event: NSEvent) { hovered = true; refreshAppearance() }
        override func mouseExited(with event: NSEvent) { hovered = false; refreshAppearance() }
        override func highlight(_ flag: Bool) { super.highlight(flag); refreshAppearance() }

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
