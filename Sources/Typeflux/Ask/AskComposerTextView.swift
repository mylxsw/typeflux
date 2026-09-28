import AppKit
import SwiftUI

/// A native editor keeps IME composition, selection and the existing dictation
/// insertion path intact. Return confirms only after marked text is committed.
struct AskComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var placeholder: String
    var voice: AskVoiceInput? = nil
    var contextID: String = "launcher"
    var onSubmit: () -> Void
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = Editor()
        editor.identifier = NSUserInterfaceItemIdentifier("ask.composer")
        editor.isRichText = false
        editor.isEditable = isEnabled
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: StudioTheme.Typography.bodyLarge)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.voice = voice
        editor.contextID = contextID
        editor.onSubmit = onSubmit
        editor.onDismiss = onDismiss
        editor.onHeightChange = onHeightChange
        editor.setAccessibilityLabel(placeholder)
        editor.setAccessibilityHelp(L("ask.voice.holdHint"))
        scroll.documentView = editor
        editor.string = text
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window else { return }
            window.makeFirstResponder(editor)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.contextID != contextID { editor.voice?.cancel(ifOwnedBy: editor) }
        editor.contextID = contextID
        if editor.window?.firstResponder === editor, voice?.focusedContext != contextID {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window?.firstResponder === editor else { return }
                editor.voice?.focusedContext = editor.contextID
            }
        }
        editor.voice = voice
        editor.isEditable = isEnabled
        editor.onSubmit = onSubmit; editor.onDismiss = onDismiss
        editor.onHeightChange = onHeightChange
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        editor.reportHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AskComposerTextView
        init(_ parent: AskComposerTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            (editor as? Editor)?.reportHeight()
        }
    }

    final class Editor: NSTextView, NSGestureRecognizerDelegate {
        weak var voice: AskVoiceInput?
        var contextID = "launcher"
        private var holdGesture: NSPressGestureRecognizer?
        private var globalReleaseMonitor: Any?
        private var windowObserver: NSObjectProtocol?
        private var mouseRecording = false
        var onSubmit: () -> Void = {}
        var onDismiss: () -> Void = {}
        var onHeightChange: (CGFloat) -> Void = { _ in }
        private var reportedHeight: CGFloat = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if holdGesture == nil {
                let press = NSPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
                press.minimumPressDuration = 0.35
                press.allowableMovement = 6
                press.buttonMask = 1
                press.delegate = self
                addGestureRecognizer(press)
                holdGesture = press
            }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
            guard let window else { cancelInteraction(); return }
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.cancelInteraction()
            }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { voice?.focusedContext = contextID }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted {
                cancelInteraction()
                if voice?.focusedContext == contextID { voice?.focusedContext = nil }
            }
            return accepted
        }
        func cancelInteraction() {
            clearMouseTracking()
            voice?.cancel(ifOwnedBy: self)
        }
        private func clearMouseTracking() {
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor); self.globalReleaseMonitor = nil }
            mouseRecording = false
        }
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard event.type == .leftMouseDown, event.clickCount == 1, isEditable,
                  voice?.isOccupied == false, !hasMarkedText(),
                  event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty else { return false }
            window?.makeFirstResponder(self)
            return true
        }
        @objc private func handleHold(_ gesture: NSPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                // NSPressGestureRecognizer defers native selection until the hold
                // fails. A short click/drag still reaches NSTextView unchanged.
                let index = characterIndexForInsertion(at: gesture.location(in: self))
                let selected = selectedRange()
                if selected.length == 0 || index < selected.location || index > NSMaxRange(selected) {
                    setSelectedRange(NSRange(location: index, length: 0))
                }
                mouseRecording = voice?.begin(in: self) == true
                if mouseRecording {
                    globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.finishMouseHold() }
                }
            case .ended: finishMouseHold()
            case .cancelled:
                if mouseRecording { voice?.cancel(ifOwnedBy: self) }
                clearMouseTracking()
            default: break
            }
        }
        private func finishMouseHold() {
            if mouseRecording { voice?.stop() }
            clearMouseTracking()
        }
        deinit {
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor) }
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        }
        override func layout() { super.layout(); reportHeight() }
        func reportHeight() {
            guard let layoutManager, let textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let height = min(148, max(32, ceil(layoutManager.usedRect(for: textContainer).height + 12)))
            guard height != reportedHeight else { return }
            reportedHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeightChange(height) }
        }
        override func keyDown(with event: NSEvent) {
            if voice?.isActive == true {
                if event.keyCode == 53 { cancelInteraction() }
                return
            }
            if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSubmit(); return
            }
            if event.keyCode == 53, !hasMarkedText() { onDismiss(); return }
            super.keyDown(with: event)
        }
    }
}
