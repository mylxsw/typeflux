import AppKit
import ApplicationServices
import Foundation
import os

final class AXTextInjector: TextInjector {

    private let logger = Logger(subsystem: "dev.typeflux", category: "AXTextInjector")
    private struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    private struct SelectionContext {
        let element: AXUIElement
        let range: CFRange?
        let processID: pid_t?
        let processName: String?
        let role: String?
        let windowTitle: String?
        let isFocusedTarget: Bool
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
                isEditable: false,
                role: nil,
                windowTitle: nil,
                isFocusedTarget: false
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        logger.debug("getSelectionSnapshot — app: \(processName ?? "?", privacy: .public) (pid: \(processID.map(String.init) ?? "?", privacy: .public))")

        if let result = readSelectedTextWithTimeout(milliseconds: Self.selectedTextTimeoutMilliseconds) {
            // Compute editability from the SAME element that produced the text,
            // avoiding a race where a second focusedElement() call returns a different element.
            let editability = isLikelyEditable(element: result.context.element)
            latestSelectionContext = result.context
            logger.debug("source=ax-api  role=\(result.context.role ?? "nil", privacy: .public)  range=\(result.context.range.map { "[\($0.location),\($0.length)]" } ?? "nil", privacy: .public)  isEditable=\(editability ? "true" : "false", privacy: .public)  isFocusedTarget=\(result.context.isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(result.text.prefix(32)), privacy: .public)")
            return TextSelectionSnapshot(
                processID: result.context.processID,
                processName: result.context.processName,
                selectedRange: result.context.range,
                selectedText: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                source: result.context.source,
                isEditable: editability,
                role: result.context.role,
                windowTitle: result.context.windowTitle,
                isFocusedTarget: result.context.isFocusedTarget
            )
        }
        logger.debug("ax-api returned nil — trying clipboard-copy")

        if let copiedText = readSelectedTextViaCopy(processID: processID, milliseconds: Self.copySelectionTimeoutMilliseconds) {
            let focusedElement = focusedElement()
            let focusedWindow = processID.flatMap(focusedWindowElement(for:))
            let selectionWindow = focusedElement.flatMap(containingWindow(of:))
            // Clipboard copy succeeded → text IS selected in the frontmost app's process.
            // When selectionWindow is nil (e.g. Electron/Chromium AX hierarchy doesn't expose
            // a traversable parent chain to the window), we still trust isFocusedTarget = true
            // because the Cmd+C was sent to processID (the frontmost app) and succeeded.
            let isFocusedTarget = focusedWindow.map { w in
                selectionWindow.map { s in windowsMatch(w, s) } ?? true
            } ?? (focusedElement != nil)
            let context = SelectionContext(
                element: focusedElement ?? AXUIElementCreateSystemWide(),
                range: nil,
                processID: processID,
                processName: processName,
                role: nil,
                windowTitle: selectionWindow.flatMap(windowTitle(of:)) ?? focusedWindowTitle(for: processID),
                isFocusedTarget: isFocusedTarget,
                source: "clipboard-copy",
                capturedAt: Date()
            )
            latestSelectionContext = context
            logger.debug("source=clipboard-copy  focusedWindow=\(focusedWindow != nil ? "present" : "nil", privacy: .public)  selectionWindow=\(selectionWindow != nil ? "present" : "nil", privacy: .public)  isFocusedTarget=\(isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(copiedText.prefix(32)), privacy: .public)")
            // Cmd+C succeeded → the field accepts clipboard operations → Cmd+V should work.
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                selectedRange: nil,
                selectedText: copiedText,
                source: "clipboard-copy",
                isEditable: true,
                role: nil,
                windowTitle: context.windowTitle,
                isFocusedTarget: context.isFocusedTarget
            )
        }
        logger.debug("clipboard-copy returned nil — no selection detected")

        let focused = focusedElement()
        let editability = focused.map(isLikelyEditable(element:)) ?? false
        latestSelectionContext = nil
        return TextSelectionSnapshot(
            processID: processID,
            processName: processName,
            selectedRange: nil,
            selectedText: nil,
            source: "none",
            isEditable: editability,
            role: focused.flatMap { copyStringAttribute(kAXRoleAttribute as String, from: $0) },
            windowTitle: focused.flatMap(containingWindowTitle(of:)),
            isFocusedTarget: false
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
        if let processID = frontmostProcessID(),
           let focused = focusedElement(for: processID) {
            return focused
        }

        return systemFocusedElement()
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

        let processID = frontmostProcessID()
        let focusedWindow = processID.flatMap(focusedWindowElement(for:))
        let selectionWindow = containingWindow(of: element)
        let isFocusedTarget = focusedWindow.map { windowsMatch($0, selectionWindow) } ?? false

        let context = SelectionContext(
            element: element,
            range: range,
            processID: processID,
            processName: frontmostApplicationName(),
            role: role,
            windowTitle: selectionWindow.flatMap(windowTitle(of:)),
            isFocusedTarget: isFocusedTarget,
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
        let previousSnapshot = capturePasteboardSnapshot(from: pasteboard)
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

        restorePasteboardAfterPaste(previousSnapshot)
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

    private func systemFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: system),
           let resolved = resolveFocusedElement(focused) {
            return resolved
        }

        return nil
    }

    private func focusedElement(for processID: pid_t) -> AXUIElement? {
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

    private func focusedWindowElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)
        return copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement)
    }

    private func focusedWindowTitle(for processID: pid_t?) -> String? {
        guard let processID, let window = focusedWindowElement(for: processID) else { return nil }
        return windowTitle(of: window)
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

    private func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        var depthRemaining = Self.focusedDescendantSearchDepth + 10

        while let node = current, depthRemaining > 0 {
            if copyStringAttribute(kAXRoleAttribute as String, from: node) == kAXWindowRole as String {
                return node
            }

            current = copyElementAttribute(kAXParentAttribute as String, from: node)
            depthRemaining -= 1
        }

        return nil
    }

    private func containingWindowTitle(of element: AXUIElement) -> String? {
        guard let window = containingWindow(of: element) else { return nil }
        return windowTitle(of: window)
    }

    private func windowTitle(of window: AXUIElement) -> String? {
        copyTextAttribute(kAXTitleAttribute as String, from: window)
    }

    private func windowsMatch(_ lhs: AXUIElement, _ rhs: AXUIElement?) -> Bool {
        guard let rhs else { return false }
        if CFEqual(lhs, rhs) {
            return true
        }

        let lhsTitle = windowTitle(of: lhs)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhsTitle = windowTitle(of: rhs)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lhsTitle, let rhsTitle, !lhsTitle.isEmpty, lhsTitle == rhsTitle {
            return true
        }

        let lhsPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: lhs)
        let rhsPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: rhs)
        let lhsSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: lhs)
        let rhsSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: rhs)

        return lhsPosition == rhsPosition && lhsSize == rhsSize
    }

    private func copyBooleanAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

        let typedValue = axValue as! AXValue
        guard AXValueGetType(typedValue) == .cgPoint else { return nil }

        var output = CGPoint.zero
        guard AXValueGetValue(typedValue, .cgPoint, &output) else { return nil }
        return output
    }

    private func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }

        let typedValue = axValue as! AXValue
        guard AXValueGetType(typedValue) == .cgSize else { return nil }

        var output = CGSize.zero
        guard AXValueGetValue(typedValue, .cgSize, &output) else { return nil }
        return output
    }

    private func readSelectedTextViaCopy(processID: pid_t?, milliseconds: Int) -> String? {
        let pasteboard = NSPasteboard.general
        let previousSnapshot = capturePasteboardSnapshot(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        sendCopyShortcut(to: processID)

        let timeout = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < timeout {
            if pasteboard.changeCount != previousChangeCount {
                let copiedText = pasteboard.string(forType: .string)
                restorePasteboardAfterPaste(previousSnapshot)
                let trimmed = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty == false) ? trimmed : nil
            }
            usleep(10_000)
        }

        restorePasteboardAfterPaste(previousSnapshot)
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

    private func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            let representations = item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else { return }

        let restoredItems = snapshot.items.map { snapshotItem in
            let item = NSPasteboardItem()
            for representation in snapshotItem.representations {
                item.setData(representation.data, forType: representation.type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }

    private func restorePasteboardAfterPaste(_ previousSnapshot: PasteboardSnapshot) {
        Task.detached {
            try? await Task.sleep(nanoseconds: Self.pasteRestoreDelayNanoseconds)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                self.restorePasteboard(previousSnapshot, to: pasteboard)
            }
        }
    }
}
