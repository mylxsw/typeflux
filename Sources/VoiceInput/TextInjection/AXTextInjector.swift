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

        return copyStringAttribute(kAXSelectedTextAttribute, from: element)
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

        guard
            let currentValue = copyStringAttribute(kAXValueAttribute, from: element),
            let selectedRange = copySelectedTextRange(from: element)
        else {
            return false
        }

        let nsValue = currentValue as NSString
        let maxLength = nsValue.length
        let safeLocation = min(max(0, selectedRange.location), maxLength)
        let safeLength = min(max(0, selectedRange.length), maxLength - safeLocation)
        let range = NSRange(location: safeLocation, length: replaceSelection ? safeLength : 0)
        let updatedValue = nsValue.replacingCharacters(in: range, with: text)

        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )
        guard setValueResult == .success else {
            return false
        }

        let insertionLocation = safeLocation + (text as NSString).length
        _ = setSelectedTextRange(
            CFRange(location: insertionLocation, length: 0),
            on: element
        )
        return true
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
