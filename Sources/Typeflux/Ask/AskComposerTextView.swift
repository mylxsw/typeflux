import AppKit
import SwiftUI

/// A native editor keeps IME composition, selection and the existing dictation
/// insertion path intact. Return confirms only after marked text is committed.
struct AskComposerTextView: NSViewRepresentable {
    /// Horizontal inset of the text inside its container. The SwiftUI
    /// placeholder uses the same value so it starts where the caret does.
    static let lineFragmentPadding: CGFloat = 5
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    var placeholder: String
    var voice: AskVoiceInput? = nil
    var contextID: String = "launcher"
    var fontSize: CGFloat = StudioTheme.Typography.bodyLarge
    var maximumHeight: CGFloat = 148
    var onSubmit: () -> Void
    var onDismiss: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Receives files and images pasted (⌘V, Edit menu or context menu) or dropped
    /// on the editor. Nil keeps the plain text behaviour.
    var onAttach: (([AskAttachmentSource]) -> Void)?
    var onDropTargetChange: (Bool) -> Void = { _ in }
    /// The slash token before the caret after each edit or caret move, and
    /// whether the user typed the change (pastes and dictation do not open commands).
    var onSlashQuery: ((AskSlashQuery?, Bool) -> Void)?
    /// Arrow, Return, Tab and Escape while the command palette is open; true when handled.
    var onCommandKey: ((AskCommandKey) -> Bool)?
    /// Delete in an empty editor; true when it removed something instead.
    var onEmptyBackspace: (() -> Bool)?
    /// ⌘K; true when handled.
    var onContextShortcut: (() -> Bool)?

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
        editor.font = .systemFont(ofSize: fontSize)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = Self.lineFragmentPadding
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
        editor.maximumHeight = maximumHeight
        editor.onAttach = onAttach
        editor.onDropTargetChange = onDropTargetChange
        editor.onSlashQuery = onSlashQuery
        editor.onCommandKey = onCommandKey
        editor.onEmptyBackspace = onEmptyBackspace
        editor.onContextShortcut = onContextShortcut
        editor.setAccessibilityLabel(placeholder)
        editor.setAccessibilityHelp(L("ask.voice.holdHint"))
        scroll.documentView = editor
        editor.string = text
        DispatchQueue.main.async { [weak editor] in
            guard let editor, let window = editor.window, window.isKeyWindow else { return }
            window.makeFirstResponder(editor)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.contextID != contextID { editor.voice?.cancel(ifOwnedBy: editor) }
        editor.contextID = contextID
        editor.voice = voice
        // An inactive window retains its first responder. It must not compete
        // with the key window for the shared composer's focus state.
        if editor.window?.isKeyWindow == true, editor.window?.firstResponder === editor,
           voice?.focusedContext != contextID {
            DispatchQueue.main.async { [weak editor] in editor?.publishFocus() }
        }
        if editor.isEditable != isEnabled { editor.isEditable = isEnabled }
        editor.onSubmit = onSubmit; editor.onDismiss = onDismiss
        editor.onHeightChange = onHeightChange
        editor.maximumHeight = maximumHeight
        editor.onAttach = onAttach
        editor.onDropTargetChange = onDropTargetChange
        editor.onSlashQuery = onSlashQuery
        editor.onCommandKey = onCommandKey
        editor.onEmptyBackspace = onEmptyBackspace
        editor.onContextShortcut = onContextShortcut
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize) }
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
            (editor as? Editor)?.reportSlash()
        }
        /// `updateNSView` moves the caret while SwiftUI is updating; report on the next
        /// turn so the composer never changes its state in the middle of an update.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? Editor else { return }
            DispatchQueue.main.async { [weak editor] in editor?.reportSlash() }
        }
    }

    final class Editor: NSTextView {
        weak var voice: AskVoiceInput?
        var contextID = "launcher"
        static let mouseHoldDelay: TimeInterval = 0.35
        private var holdTimer: Timer?
        private var mouseDownEvent: NSEvent?
        private var mouseInsertionIndex = 0
        private var localReleaseMonitor: Any?
        private var inputMonitor: Any?
        private var globalReleaseMonitor: Any?
        private var windowObservers: [NSObjectProtocol] = []
        private var mouseRecording = false
        private var mouseSelecting = false
        var onSubmit: () -> Void = {}
        var onDismiss: () -> Void = {}
        var onHeightChange: (CGFloat) -> Void = { _ in }
        var onAttach: (([AskAttachmentSource]) -> Void)?
        var onDropTargetChange: (Bool) -> Void = { _ in }
        var onSlashQuery: ((AskSlashQuery?, Bool) -> Void)?
        var onCommandKey: ((AskCommandKey) -> Bool)?
        var onEmptyBackspace: (() -> Bool)?
        var onContextShortcut: (() -> Bool)?
        /// A key press is being handled; edits made now were typed.
        private(set) var typing = false
        private var reportedHeight: CGFloat = 0
        var maximumHeight: CGFloat = 148

        func reportSlash() {
            guard let onSlashQuery, !hasMarkedText() else { return }
            let caret = selectedRange()
            onSlashQuery(caret.length == 0 ? AskSlashQuery.parse(string, caret: caret.location) : nil, typing)
        }

        /// Hands files or images on `pasteboard` to `onAttach`; false leaves it to the text system.
        @discardableResult
        func attach(from pasteboard: NSPasteboard, textWins: Bool = true) -> Bool {
            guard let onAttach, isEditable, AskAttachmentSource.canRead(from: pasteboard, textWins: textWins) else { return false }
            let sources = AskAttachmentSource.read(from: pasteboard, textWins: textWins)
            guard !sources.isEmpty else { return false }
            onAttach(sources)
            return true
        }
        override func paste(_ sender: Any?) {
            if !attach(from: .general) { super.paste(sender) }
        }
        override func pasteAsPlainText(_ sender: Any?) {
            if !attach(from: .general) { super.pasteAsPlainText(sender) }
        }
        /// A plain text view disables Paste for an image-only pasteboard; attaching makes it valid.
        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            if [#selector(paste(_:)), #selector(pasteAsPlainText(_:))].contains(item.action),
               onAttach != nil, isEditable, AskAttachmentSource.canRead(from: .general) { return true }
            return super.validateUserInterfaceItem(item)
        }
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            super.acceptableDragTypes + [.fileURL, .png, .tiff]
        }
        private func attachesDrop(_ sender: NSDraggingInfo) -> Bool {
            onAttach != nil && isEditable && AskAttachmentSource.canRead(from: sender.draggingPasteboard, textWins: false)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard attachesDrop(sender) else { return super.draggingEntered(sender) }
            onDropTargetChange(true)
            return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            attachesDrop(sender) ? .copy : super.draggingUpdated(sender)
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            onDropTargetChange(false)
            super.draggingExited(sender)
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            attachesDrop(sender) || super.prepareForDragOperation(sender)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            onDropTargetChange(false)
            if attach(from: sender.draggingPasteboard, textWins: false) { return true }
            return super.performDragOperation(sender)
        }
        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            onDropTargetChange(false)
            super.concludeDragOperation(sender)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
            windowObservers = []
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
            guard let window else { cancelInteraction(); return }
            // Route eligible presses before AppKit/SwiftUI gesture arbitration or
            // NSTextView's selection tracker can claim the stream.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
                guard let self else { return event }
                if event.type == .leftMouseDragged, self.mouseDownEvent != nil {
                    self.mouseDragged(with: event)
                    return nil
                }
                guard event.window === self.window, self.canStartMouseHold(with: event),
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.mouseDown(with: event)
                return nil
            }
            windowObservers = [
                NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.publishFocus()
                },
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.cancelInteraction()
                    self?.clearFocus()
                }
            ]
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted, window?.isKeyWindow == true, voice?.focusedContext != contextID {
                voice?.focusedContext = contextID
            }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted {
                cancelInteraction()
                clearFocus()
            }
            return accepted
        }
        fileprivate func publishFocus() {
            guard window?.isKeyWindow == true, window?.firstResponder === self,
                  voice?.focusedContext != contextID else { return }
            voice?.focusedContext = contextID
        }
        private func clearFocus() {
            if voice?.focusedContext == contextID { voice?.focusedContext = nil }
        }
        func cancelInteraction() {
            clearMouseTracking()
            voice?.cancel(ifOwnedBy: self)
        }
        private func clearMouseTracking() {
            holdTimer?.invalidate(); holdTimer = nil
            mouseDownEvent = nil
            if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor); self.localReleaseMonitor = nil }
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor); self.globalReleaseMonitor = nil }
            mouseRecording = false
            mouseSelecting = false
        }
        func canStartMouseHold(with event: NSEvent) -> Bool {
            event.type == .leftMouseDown && event.clickCount == 1 && isEditable &&
                voice?.isOccupied == false && !hasMarkedText() &&
                event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        }
        override func mouseDown(with event: NSEvent) {
            guard voice?.isActive != true else { return }
            guard canStartMouseHold(with: event) else { super.mouseDown(with: event); return }
            window?.makeKey()
            window?.makeFirstResponder(self)
            clearMouseTracking()
            mouseDownEvent = event
            mouseInsertionIndex = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let selected = selectedRange()
            if selected.length == 0 || mouseInsertionIndex < selected.location || mouseInsertionIndex > NSMaxRange(selected) {
                setSelectedRange(NSRange(location: mouseInsertionIndex, length: 0))
            }
            // Do not enter NSTextView's synchronous selection tracking loop while
            // waiting for a hold. The main actor must be free to start the recorder.
            let timer = Timer(timeInterval: Self.mouseHoldDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.mouseDownEvent != nil else { return }
                    self.holdTimer = nil
                    self.mouseRecording = self.voice?.begin(in: self) == true
                }
            }
            holdTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            // A release can land outside this editor or even outside the app.
            localReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, self.mouseDownEvent != nil else { return event }
                self.finishMouseHold()
                return nil
            }
            globalReleaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.finishMouseHold() }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent else { super.mouseDragged(with: event); return }
            guard !mouseRecording else { return }
            let delta = NSPoint(x: event.locationInWindow.x - down.locationInWindow.x,
                                y: event.locationInWindow.y - down.locationInWindow.y)
            guard mouseSelecting || hypot(delta.x, delta.y) > 6 else { return }
            holdTimer?.invalidate(); holdTimer = nil
            mouseSelecting = true
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            setSelectedRange(NSRange(location: min(mouseInsertionIndex, index), length: abs(index - mouseInsertionIndex)))
            autoscroll(with: event)
        }
        override func mouseUp(with event: NSEvent) {
            guard mouseDownEvent != nil else { super.mouseUp(with: event); return }
            finishMouseHold()
        }
        private func finishMouseHold() {
            guard mouseDownEvent != nil else { return }
            if mouseRecording { voice?.stop() }
            else if !mouseSelecting { setSelectedRange(NSRange(location: mouseInsertionIndex, length: 0)) }
            clearMouseTracking()
        }
        deinit {
            holdTimer?.invalidate()
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
            if let localReleaseMonitor { NSEvent.removeMonitor(localReleaseMonitor) }
            if let globalReleaseMonitor { NSEvent.removeMonitor(globalReleaseMonitor) }
            windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        }
        override func layout() { super.layout(); reportHeight() }
        func reportHeight() {
            guard let layoutManager, let textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height + 12)
            let height = min(max(32, maximumHeight), max(32, contentHeight))
            guard height != reportedHeight else { return }
            reportedHeight = height
            DispatchQueue.main.async { [weak self] in self?.onHeightChange(height) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if Self.isContextShortcut(event), window?.firstResponder === self, voice?.isActive != true,
               onContextShortcut?() == true { return true }
            return super.performKeyEquivalent(with: event)
        }
        static func isContextShortcut(_ event: NSEvent) -> Bool {
            event.type == .keyDown && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                && event.charactersIgnoringModifiers?.lowercased() == "k"
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53, mouseDownEvent != nil { cancelInteraction(); return }
            if voice?.isActive == true {
                if event.keyCode == 53 { cancelInteraction() }
                // Return finishes recording and fills in the words, like the stop button.
                if event.keyCode == 36 || event.keyCode == 76, voice?.phase == .listening,
                   voice?.context == contextID { voice?.stop() }
                return
            }
            if event.keyCode == 51, string.isEmpty, !hasMarkedText(),
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               onEmptyBackspace?() == true { return }
            if !hasMarkedText(), let key = AskCommandKey(event), onCommandKey?(key) == true { return }
            if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSubmit(); return
            }
            if event.keyCode == 53, !hasMarkedText() { onDismiss(); return }
            typing = true
            defer { typing = false }
            super.keyDown(with: event)
        }
    }
}
