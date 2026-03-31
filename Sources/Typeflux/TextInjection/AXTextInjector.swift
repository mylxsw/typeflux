import AppKit
import ApplicationServices
import Foundation

final class AXTextInjector: TextInjector {
    private struct SelectionContext {
        let element: AXUIElement
        let range: CFRange?
        let processID: pid_t?
        let processName: String?
        let source: String
        let capturedAt: Date
    }

    private static var didRequestAccessibility = false
    private static let pasteRestoreDelayNanoseconds: UInt64 = 180_000_000
    private static let focusRestoreDelayMicroseconds: useconds_t = 250_000
    private static let selectedTextTimeoutMilliseconds = 200
    private static let copySelectionTimeoutMilliseconds = 180
    private static let copyShortcutKeyCode: CGKeyCode = 8
    private static let selectionContextLifetime: TimeInterval = 180
    private static let focusedDescendantSearchDepth = 6

    private var latestSelectionContext: SelectionContext?

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        guard AXIsProcessTrusted() else {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return TextSelectionSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                selectedRange: nil,
                selectedText: nil,
                source: "unavailable",
                isEditable: false
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()

        if let result = readSelectedTextWithTimeout(milliseconds: Self.selectedTextTimeoutMilliseconds) {
            // Compute editability from the SAME element that produced the text,
            // avoiding a race where a second focusedElement() call returns a different element.
            let editability = isLikelyEditable(element: result.context.element)
            latestSelectionContext = result.context
            return TextSelectionSnapshot(
                processID: result.context.processID,
                processName: result.context.processName,
                selectedRange: result.context.range,
                selectedText: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                source: result.context.source,
                isEditable: editability
            )
        }

        if let copiedText = readSelectedTextViaCopy(processID: processID, milliseconds: Self.copySelectionTimeoutMilliseconds) {
            let context = SelectionContext(
                element: focusedElement() ?? AXUIElementCreateSystemWide(),
                range: nil,
                processID: processID,
                processName: processName,
                source: "clipboard-copy",
                capturedAt: Date()
            )
            latestSelectionContext = context
            // Cmd+C succeeded → the field accepts clipboard operations → Cmd+V should work.
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                selectedRange: nil,
                selectedText: copiedText,
                source: "clipboard-copy",
                isEditable: true
            )
        }

            let editability = focusedElement().map(isLikelyEditable(element:)) ?? false
            latestSelectionContext = nil
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                selectedRange: nil,
                selectedText: nil,
                source: "none",
                isEditable: editability
            )
    }

    func insert(text: String) throws {
        try setText(text, replaceSelection: false)
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        guard AXIsProcessTrusted() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                role: nil,
                text: nil,
                isEditable: false,
                failureReason: "accessibility-not-trusted"
            )
        }

        guard let element = focusedElement() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                role: nil,
                text: nil,
                isEditable: false,
                failureReason: "no-focused-element"
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isEditable = isLikelyEditable(element: element)

        guard isEditable else {
            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                role: role,
                text: nil,
                isEditable: false,
                failureReason: "focused-element-not-editable"
            )
        }

        if let value = copyTextAttribute(kAXValueAttribute as String, from: element) {
            if let placeholder = copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element), placeholder == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    role: role,
                    text: nil,
                    isEditable: true,
                    failureReason: "value-matched-placeholder"
                )
            }
            if let title = copyTextAttribute(kAXTitleAttribute as String, from: element), title == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    role: role,
                    text: nil,
                    isEditable: true,
                    failureReason: "value-matched-title"
                )
            }

            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                role: role,
                text: value,
                isEditable: true,
                failureReason: nil
            )
        }

        return CurrentInputTextSnapshot(
            processID: processID,
            processName: processName,
            role: role,
            text: nil,
            isEditable: true,
            failureReason: "missing-ax-value"
        )
    }

    func currentInputText() async -> String? {
        await currentInputTextSnapshot().text
    }

    func replaceSelection(text: String) throws {
        try setText(text, replaceSelection: true)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: system),
           let resolved = resolveFocusedElement(focused) {
            return resolved
        }

        guard let processID = frontmostProcessID() else { return nil }
        let appElement = AXUIElementCreateApplication(processID)

        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focused) {
            return resolved
        }

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focusedWindow) {
            return resolved
        }

        return nil
    }

    private func readSelectedTextWithTimeout(milliseconds: Int) -> (text: String, context: SelectionContext)? {
        final class Box: @unchecked Sendable {
            var value: (text: String, context: SelectionContext)?
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = self.readSelectedText()
            semaphore.signal()
        }

        let timeout = DispatchTime.now() + .milliseconds(milliseconds)
        guard semaphore.wait(timeout: timeout) != .timedOut else {
            return nil
        }

        return box.value
    }

    private func readSelectedText() -> (text: String, context: SelectionContext)? {
        guard let element = focusedElement() else {
            return nil
        }

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let nativeTextRoles: Set<String> = [
            "AXTextArea",
            "AXTextField",
            "AXComboBox",
            "AXSearchField"
        ]
        let isNativeText = role != nil && nativeTextRoles.contains(role!)

        let isSettable = isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
                      || isAttributeSettable(kAXValueAttribute as CFString, on: element)
                      || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)

        if !isNativeText && !isSettable {
            return nil
        }

        let range = copySelectedTextRange(from: element)
        if let r = range, r.length == 0 {
            return nil
        }

        guard let text = copyStringAttribute(kAXSelectedTextAttribute, from: element) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // Electron Bug Defense 1: Fake selection exactly matches Placeholder or Title
        if let placeholder = copyStringAttribute(kAXPlaceholderValueAttribute as String, from: element), placeholder == text {
            return nil
        }
        if let title = copyStringAttribute(kAXTitleAttribute as String, from: element), title == text {
            return nil
        }

        // Electron Bug Defense 2: Fake selection matches the entire node's value, but the node refuses to provide a selection range.
        // This usually happens when an Electron WebArea focuses a block but hasn't actually selected any text inside it.
        if range == nil && (role == "AXWebArea" || role == "AXGroup" || role == "AXUnknown") {
            if let value = copyStringAttribute(kAXValueAttribute as String, from: element), value == text {
                return nil
            }
        }

        guard let range else { return nil }

        let context = SelectionContext(
            element: element,
            range: range,
            processID: frontmostProcessID(),
            processName: frontmostApplicationName(),
            source: "accessibility",
            capturedAt: Date()
        )

        return (text, context)
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
    }

    private func isLikelyEditable(element: AXUIElement) -> Bool {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let nativeTextRoles: Set<String> = [
            "AXTextArea",
            "AXTextField",
            "AXComboBox",
            "AXSearchField"
        ]
        if let role, nativeTextRoles.contains(role) {
            return true
        }

        return isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
    }

    private func setText(_ text: String, replaceSelection: Bool) throws {
        if !AXIsProcessTrusted() {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            throw NSError(
                domain: "AXTextInjector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Accessibility permission required"]
            )
        }

        var contextRestored = false

        if replaceSelection,
           let context = activeSelectionContext() {
            restoreSelectionContext(context)
            contextRestored = true
            if context.range != nil,
               try insertTextViaAX(text, into: context.element, replaceSelection: true, selectionRange: context.range) {
                latestSelectionContext = nil
                return
            }
        }

        if let element = focusedElement(), try insertTextViaAX(text, into: element, replaceSelection: replaceSelection, selectionRange: nil) {
            if replaceSelection {
                latestSelectionContext = nil
            }
            return
        }

        try setTextViaPaste(text, replaceSelection: replaceSelection, contextAlreadyRestored: contextRestored)
        if replaceSelection {
            latestSelectionContext = nil
        }
    }

    private func insertTextViaAX(_ text: String, into element: AXUIElement, replaceSelection: Bool, selectionRange: CFRange?) throws -> Bool {
        if replaceSelection {
            if let selectionRange {
                _ = setSelectedTextRange(selectionRange, on: element)
            }
            let replaceSelectedText = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if replaceSelectedText == .success {
                return true
            }
        }

        // EXTREMELY DANGEROUS: 
        // We previously attempted to read `kAXValueAttribute`, string-splice the new text into it, and set it back.
        // However, many Electron apps (like Codex) expose their placeholder text inside `kAXValueAttribute` when empty.
        // String splicing here permanently fuses the user's dictation with the placeholder (e.g. "Ask for follow-up changes")
        // and physically writes it into the document. Furthermore, mutating `kAXValueAttribute` breaks Undo/Redo across macOS.
        // By returning false, we securely delegate all standard insertions to `setTextViaPaste` (Cmd+V), which works natively.
        return false
    }

    private func setTextViaPaste(_ text: String, replaceSelection: Bool, contextAlreadyRestored: Bool = false) throws {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let targetPID: pid_t?

        if replaceSelection, let context = activeSelectionContext() {
            targetPID = context.processID
            if !contextAlreadyRestored {
                restoreSelectionContext(context)
            }
        } else {
            targetPID = frontmostProcessID()
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)

        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // kVK_ANSI_V
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        if let targetPID {
            vDown?.postToPid(targetPID)
            vUp?.postToPid(targetPID)
        } else {
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }

        restorePasteboardAfterPaste(previousString)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyElementArrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(item, to: AXUIElement.self)
        }
    }

    private func copyTextAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else { return nil }

        if let string = value as? String {
            return string
        }

        if let attributed = value as? NSAttributedString {
            return attributed.string
        }

        return nil
    }

    private func copySelectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

        let rangeValue = axValue as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    private func setSelectedTextRange(_ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return false }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        )
        return result == .success
    }

    @discardableResult
    private func setFocused(_ focused: Bool, on element: AXUIElement) -> Bool {
        let value: CFBoolean = focused ? true as CFBoolean : false as CFBoolean
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            value
        )
        return result == .success
    }

    private func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func frontmostApplicationName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func resolveFocusedElement(_ element: AXUIElement) -> AXUIElement? {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)

        if role != "AXWindow" {
            return element
        }

        if let nestedFocused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: element),
           nestedFocused != element,
           let resolved = resolveFocusedElement(nestedFocused) {
            return resolved
        }

        if let descendant = findFocusedDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth
        ) {
            return descendant
        }

        return element
    }

    private func findFocusedDescendant(in element: AXUIElement, depthRemaining: Int) -> AXUIElement? {
        guard depthRemaining > 0 else { return nil }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        for child in children {
            if let focused = copyBooleanAttribute(kAXFocusedAttribute as String, from: child), focused {
                return child
            }
            if let nested = findFocusedDescendant(in: child, depthRemaining: depthRemaining - 1) {
                return nested
            }
        }

        return nil
    }

    private func copyBooleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private func readSelectedTextViaCopy(processID: pid_t?, milliseconds: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        sendCopyShortcut(to: processID)

        let timeout = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < timeout {
            if pasteboard.changeCount != previousChangeCount {
                let copiedText = pasteboard.string(forType: .string)
                restorePasteboardAfterPaste(previousString)
                let trimmed = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty == false) ? trimmed : nil
            }
            usleep(10_000)
        }

        restorePasteboardAfterPaste(previousString)
        return nil
    }

    private func sendCopyShortcut(to processID: pid_t?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: Self.copyShortcutKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: Self.copyShortcutKeyCode, keyDown: false)
        up?.flags = .maskCommand

        if let processID {
            down?.postToPid(processID)
            up?.postToPid(processID)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func activeSelectionContext() -> SelectionContext? {
        guard let latestSelectionContext else { return nil }
        guard Date().timeIntervalSince(latestSelectionContext.capturedAt) <= Self.selectionContextLifetime else {
            self.latestSelectionContext = nil
            return nil
        }
        return latestSelectionContext
    }

    private func restoreSelectionContext(_ context: SelectionContext) {
        if let processID = context.processID,
           let app = NSRunningApplication(processIdentifier: processID) {
            app.activate(options: [.activateIgnoringOtherApps])

            // Wait for the target app to actually become frontmost.
            // Some apps (WeChat, Sublime Text, Electron) need extra time.
            let deadline = Date().addingTimeInterval(0.8)
            var activated = false
            while Date() < deadline {
                usleep(50_000) // 50ms per check
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                    activated = true
                    break
                }
            }

            if !activated {
                // Retry activation once and give a final wait
                app.activate(options: [.activateIgnoringOtherApps])
                usleep(Self.focusRestoreDelayMicroseconds)
            }
        }

        _ = setFocused(true, on: context.element)
        if let range = context.range {
            _ = setSelectedTextRange(range, on: context.element)
        }
    }

    private func restorePasteboardAfterPaste(_ previousString: String?) {
        Task.detached {
            try? await Task.sleep(nanoseconds: Self.pasteRestoreDelayNanoseconds)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                if let previousString {
                    pasteboard.setString(previousString, forType: .string)
                }
            }
        }
    }
}
