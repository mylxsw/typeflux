import AppKit
import ApplicationServices
import Foundation

extension AXTextInjector {
    @MainActor
    func deliver(text: String, to destination: TextDeliveryDestination) async throws -> TextDeliveryResult {
        try Task.checkCancellation()
        try await acquireTextOperation()
        defer { deliveryInProgress = false }

        let context: SelectionContext?
        if case let .selection(snapshot) = destination, snapshot.source != "typeflux-native" {
            guard snapshot.canReplaceSelection,
                  let id = snapshot.replacementContextID,
                  let captured = consumeSelectionContext(id: id)
            else { throw TextDeliveryError.selectionChanged }
            context = captured
        } else {
            context = nil
        }
        defer {
            if let context { clearLatestSelectionContext(ifMatching: context) }
        }
        let backend = AXTextDeliveryBackend(injector: self, selection: context)
        return try await TextDeliveryCoordinator(backend: backend).deliver(text, to: destination)
    }
}

/// AppKit state is main-actor isolated; bounded external AX operations run on the
/// injector's serial queue. No document scraping or application-state lookup is
/// needed to deliver text.
@MainActor
final class AXTextDeliveryBackend: TextDeliveryBackend {
    struct ExternalTarget {
        let element: AXUIElement
        let processID: pid_t
        let range: CFRange?
        let before: String?
        var contentBefore: String? = nil
    }

    enum Target {
        case native(NSTextView, NSWindow, NSRange, String)
        case external(ExternalTarget)
    }

    final class Clipboard {
        let snapshot: AXTextInjector.PasteboardSnapshot
        var changeCount: Int?
        var dispatchedAt: TimeInterval?

        init(snapshot: AXTextInjector.PasteboardSnapshot) { self.snapshot = snapshot }
    }

    private let injector: AXTextInjector
    private let selection: AXTextInjector.SelectionContext?
    private let pasteboard: NSPasteboard

    init(injector: AXTextInjector, selection: AXTextInjector.SelectionContext?, pasteboard: NSPasteboard = .general) {
        self.injector = injector
        self.selection = selection
        self.pasteboard = pasteboard
    }

    func resolve(_ destination: TextDeliveryDestination) async throws -> Target {
        try Task.checkCancellation()
        if let native = injector.typefluxNativeTextTarget(), let window = native.window {
            guard native.textView.isEditable else { throw TextDeliveryError.noInput }
            let range = native.textView.selectedRange()
            if case let .selection(snapshot) = destination {
                guard snapshot.source == "typeflux-native",
                      snapshot.nativeTarget?.textView === native.textView,
                      snapshot.nativeTarget?.window === window,
                      snapshot.selectedRange?.location == range.location,
                      snapshot.selectedRange?.length == range.length,
                      AXTextInjector.replacingUTF16Range(
                          in: native.textView.string,
                          range: CFRange(location: range.location, length: range.length), with: ""
                      ) != nil,
                      (native.textView.string as NSString).substring(with: range) == snapshot.selectedText
                else { throw TextDeliveryError.selectionChanged }
            }
            return .native(native.textView, window, range, native.textView.string)
        }
        guard AXIsProcessTrusted() else { throw TextDeliveryError.permissionRequired }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != getpid() else { throw TextDeliveryError.noInput }
        if case let .selection(snapshot) = destination, snapshot.processID != pid {
            throw TextDeliveryError.selectionChanged
        }
        let injector = injector
        let selection = selection
        return try await injector.performSelectionReplacementWork {
            let element: AXUIElement
            if let selection {
                element = try injector.validatedCurrentSelectionElement(
                    context: selection, currentFrontmostProcessID: pid, verifyClipboardText: true
                )
            } else {
                guard let focused = injector.deliveryFocusedElement(for: pid) else { throw TextDeliveryError.noInput }
                element = focused
            }
            let capability = injector.targetCapability(element: element)
            let role = injector.copyStringAttribute(kAXRoleAttribute as String, from: element) ?? "unknown"
            NetworkDebugLogger.logMessage("[Text Delivery] resolved role=\(role) capability=\(capability)")
            guard capability != .notWritable else {
                throw TextDeliveryError.noInput
            }
            let range = injector.copySelectedTextRange(from: element)
            let raw = injector.copyTextAttribute(kAXValueAttribute as String, from: element)
            let content = injector.deliveryContentValue(from: element, raw: raw, selection: range)
            return .external(ExternalTarget(
                element: element, processID: pid, range: range,
                before: raw, contentBefore: content
            ))
        }
    }

    func writeNative(_ text: String, to target: Target) async throws -> NativeTextWriteResult {
        try Task.checkCancellation()
        switch target {
        case let .native(view, window, range, before):
            guard NSApp.keyWindow === window, window.firstResponder === view,
                  view.selectedRange() == range, view.string == before else {
                throw TextDeliveryError.targetChanged
            }
            let expected = AXTextInjector.replacingUTF16Range(
                in: before, range: CFRange(location: range.location, length: range.length), with: text
            )
            view.insertText(text, replacementRange: range)
            return expected == view.string ? .acknowledged : .unconfirmed
        case .external:
            // External AX setters can report success without committing an editor
            // change. Use the editor's standard paste path instead, exactly once.
            // Accessibility remains the authority for focus and edit observation.
            return .unsupported
        }
    }

    func prepareClipboard() async throws -> Clipboard {
        let injector = injector
        let pasteboard = pasteboard
        let snapshot = try await injector.performSelectionReplacementWork {
            guard let snapshot = injector.capturePasteboardSnapshotWithTimeout(from: pasteboard) else {
                throw TextDeliveryError.clipboardUnavailable
            }
            return snapshot
        }
        return Clipboard(snapshot: snapshot)
    }

    func paste(_ text: String, to target: Target, clipboard: Clipboard) async throws {
        guard case let .external(target) = target else { throw TextDeliveryError.targetChanged }
        let injector = injector
        let cancellation = SelectionReplacementCancellationToken()
        // Build events before mutating the clipboard. Both operation intents use
        // the same HID dispatch, without reactivating the already-frontmost app.
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { throw TextDeliveryError.eventUnavailable }
        down.flags = .maskCommand
        up.flags = .maskCommand
        try await injector.performSelectionReplacementWork(cancellationToken: cancellation) {
            try Self.validate(target, injector: injector)
            try cancellation.checkCancellation()
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
            throw TextDeliveryError.targetChanged
        }
        let pasteboard = pasteboard
        guard pasteboard.changeCount == clipboard.snapshot.changeCount else {
            throw TextDeliveryError.clipboardUnavailable
        }
        guard injector.writeTransientPasteboardString(text, to: pasteboard) else {
            clipboard.changeCount = pasteboard.changeCount
            throw TextDeliveryError.clipboardUnavailable
        }
        clipboard.changeCount = pasteboard.changeCount
        clipboard.dispatchedAt = ProcessInfo.processInfo.systemUptime
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        NetworkDebugLogger.logMessage("[Text Delivery] paste dispatched; awaiting edit evidence")
    }

    func observe(_ text: String, in target: Target) async -> TextDeliveryObservation {
        if case let .native(view, _, _, before) = target {
            return view.string == before ? .unchanged : .unavailable
        }
        guard case let .external(target) = target else { return .unavailable }
        let injector = injector
        // Observe only the captured element. Never scrape another field/document
        // or send Cmd+C after writing the result to the clipboard.
        return await TextDeliveryObserver.observe(text: text, before: target.contentBefore, range: target.range) {
            try await injector.performSelectionReplacementWork {
                let raw = injector.copyTextAttribute(kAXValueAttribute as String, from: target.element)
                return injector.deliveryContentValue(
                    from: target.element, raw: raw,
                    selection: injector.copySelectedTextRange(from: target.element)
                )
            }
        }
    }

    func finishClipboard(_ clipboard: Clipboard, confirmed: Bool) async {
        guard let count = clipboard.changeCount else { return }
        if let dispatchedAt = clipboard.dispatchedAt {
            let retention: TimeInterval = confirmed ? 0.15 : 1.5
            let remaining = max(0, retention - (ProcessInfo.processInfo.systemUptime - dispatchedAt))
            // Cleanup outlives cancellation but is awaited before releasing the
            // delivery lease, so another delivery cannot snapshot our payload.
            await Task { @MainActor in
                try? await Task.sleep(for: .seconds(remaining))
            }.value
        }
        injector.restorePasteboardIfUnchanged(clipboard.snapshot, to: pasteboard, expectedChangeCount: count)
    }

    nonisolated private static func validate(_ target: ExternalTarget, injector: AXTextInjector) throws {
        guard injector.frontmostProcessID() == target.processID,
              let focused = injector.deliveryFocusedElement(for: target.processID),
              CFEqual(focused, target.element) else { throw TextDeliveryError.targetChanged }
        let currentRange = injector.copySelectedTextRange(from: focused)
        if let range = target.range {
            guard currentRange?.location == range.location, currentRange?.length == range.length else {
                throw TextDeliveryError.targetChanged
            }
        }
        if let before = target.before,
           injector.copyTextAttribute(kAXValueAttribute as String, from: focused) != before {
            throw TextDeliveryError.targetChanged
        }
    }
}
