import AppKit
import ApplicationServices
import Foundation

final class AXTextInjector: TextInjector {
    private static var didRequestAccessibility = false
    private static let pasteRestoreDelayNanoseconds: UInt64 = 180_000_000
    private static let selectedTextTimeoutMilliseconds = 200

    func getSelectedText() async -> String? {
        guard AXIsProcessTrusted() else {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        return readSelectedTextWithTimeout(milliseconds: Self.selectedTextTimeoutMilliseconds)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func insert(text: String) throws {
        try setText(text, replaceSelection: false)
    }

    func replaceSelection(text: String) throws {
        try setText(text, replaceSelection: true)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private func readSelectedTextWithTimeout(milliseconds: Int) -> String? {
        final class Box: @unchecked Sendable {
            var value: String?
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

    private func readSelectedText() -> String? {
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

        return text
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return status == .success && settable.boolValue
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

        if let element = focusedElement(), try insertTextViaAX(text, into: element, replaceSelection: replaceSelection) {
            return
        }

        try setTextViaPaste(text)
    }

    private func insertTextViaAX(_ text: String, into element: AXUIElement, replaceSelection: Bool) throws -> Bool {
        if replaceSelection {
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

    private func setTextViaPaste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let targetPID = frontmostProcessID()

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

    private func frontmostProcessID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
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
