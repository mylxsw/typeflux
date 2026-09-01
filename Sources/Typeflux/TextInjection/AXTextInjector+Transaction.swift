import AppKit
import ApplicationServices
import Foundation

extension AXTextInjector {
    enum SelectionReplacementPreparation: Equatable {
        case committedViaAX
        case requiresPaste
    }

    static func capturedSelectionStillMatches(
        source: String,
        elementMatches: Bool,
        capturedRange: CFRange?,
        currentRange: CFRange?,
        capturedText: String?,
        currentText: String?,
        capturedRole: String?,
        currentRole: String?,
        capturedSubrole: String? = nil,
        currentSubrole: String? = nil,
        capturedIdentifier: String? = nil,
        currentIdentifier: String? = nil,
        capturedPosition: CGPoint? = nil,
        currentPosition: CGPoint? = nil,
        capturedSize: CGSize? = nil,
        currentSize: CGSize? = nil,
        capturedWindowTitle: String?,
        currentWindowTitle: String?
    ) -> Bool {
        guard capturedText == currentText else {
            return false
        }

        if source != "clipboard-copy" {
            guard capturedRange?.location == currentRange?.location,
                  capturedRange?.length == currentRange?.length
            else {
                return false
            }
        }

        return capturedElementStillMatches(
            elementMatches: elementMatches,
            capturedRole: capturedRole,
            currentRole: currentRole,
            capturedSubrole: capturedSubrole,
            currentSubrole: currentSubrole,
            capturedIdentifier: capturedIdentifier,
            currentIdentifier: currentIdentifier,
            capturedPosition: capturedPosition,
            currentPosition: currentPosition,
            capturedSize: capturedSize,
            currentSize: currentSize,
            capturedWindowTitle: capturedWindowTitle,
            currentWindowTitle: currentWindowTitle,
            allowsWindowScopedMatch: source == "clipboard-copy"
        )
    }

    private static func capturedElementStillMatches(
        elementMatches: Bool,
        capturedRole: String?,
        currentRole: String?,
        capturedSubrole: String?,
        currentSubrole: String?,
        capturedIdentifier: String?,
        currentIdentifier: String?,
        capturedPosition: CGPoint?,
        currentPosition: CGPoint?,
        capturedSize: CGSize?,
        currentSize: CGSize?,
        capturedWindowTitle: String?,
        currentWindowTitle: String?,
        allowsWindowScopedMatch: Bool
    ) -> Bool {
        if elementMatches {
            return true
        }

        let identifierMatches = capturedIdentifier?.isEmpty == false && capturedIdentifier == currentIdentifier
        let frameMatches = capturedPosition != nil && capturedPosition == currentPosition &&
            capturedSize != nil && capturedSize == currentSize
        guard capturedRole == currentRole,
              capturedSubrole == currentSubrole,
              capturedRole?.isEmpty == false
        else {
            return false
        }

        let normalizedCapturedWindowTitle = capturedWindowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCurrentWindowTitle = currentWindowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let windowMatches = normalizedCapturedWindowTitle?.isEmpty == false &&
            normalizedCapturedWindowTitle == normalizedCurrentWindowTitle

        // Electron and Chromium frequently recreate the focused AX element while
        // preserving the same role and window. A fresh Cmd-C that returned the
        // original selected text is strong enough evidence for clipboard-backed
        // selections. Prefer identifier/frame when available; otherwise use the
        // focused window title, which is also captured for opaque AX hierarchies.
        if allowsWindowScopedMatch {
            return identifierMatches || frameMatches || windowMatches
        }
        return (identifierMatches || frameMatches) && windowMatches
    }

    func replaceSelection(text: String, target: TextSelectionSnapshot?) async throws {
        try Task.checkCancellation()
        if target?.source == "typeflux-native" {
            let injector = UncheckedSendableReference(self)
            try await MainActor.run {
                try Task.checkCancellation()
                guard try injector.value.insertIntoTypefluxNativeTextTarget(
                    text,
                    replaceSelection: true
                ) else {
                    throw injector.value.selectionReplacementError(
                        code: 20,
                        description: "The Typeflux selection is no longer available"
                    )
                }
                injector.value.lastInjectionMethod = .ax
            }
            return
        }

        guard let contextID = target?.replacementContextID,
              let context = consumeSelectionContext(id: contextID)
        else {
            throw selectionReplacementError(
                code: 21,
                description: "The captured selection is no longer available"
            )
        }

        try Task.checkCancellation()
        let currentProcessID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        try Task.checkCancellation()
        let preparation = try await performSelectionReplacementWork {
            try self.prepareSelectionReplacement(
                text: text,
                context: context,
                currentFrontmostProcessID: currentProcessID
            )
        }

        switch preparation {
        case .committedViaAX:
            lastInjectionMethod = .ax
        case .requiresPaste:
            try Task.checkCancellation()
            try await commitSelectionPaste(text: text, targetProcessID: context.processID)
            lastInjectionMethod = .paste
        }

        clearLatestSelectionContext(ifMatching: context)
    }

    func performSelectionReplacementWork<T>(
        _ work: @escaping () throws -> T
    ) async throws -> T {
        let sendableWork = UncheckedSendableReference(work)
        return try await withCheckedThrowingContinuation { continuation in
            selectionReplacementQueue.async {
                do {
                    continuation.resume(returning: try sendableWork.value())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func prepareSelectionReplacement(
        text: String,
        context: SelectionContext,
        currentFrontmostProcessID: pid_t?
    ) throws -> SelectionReplacementPreparation {
        let element = try validatedCurrentSelectionElement(
            context: context,
            currentFrontmostProcessID: currentFrontmostProcessID,
            verifyClipboardText: true
        )

        guard let range = context.range,
              isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
        else {
            return .requiresPaste
        }

        guard setSelectedTextRange(range, on: element) else {
            throw selectionReplacementError(
                code: 22,
                description: "The selected text range changed before replacement"
            )
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        switch result {
        case .success:
            NetworkDebugLogger.logMessage(
                "[Text Injection] selection transaction committed via AX"
            )
            return .committedViaAX
        case .attributeUnsupported, .notImplemented, .illegalArgument:
            return .requiresPaste
        default:
            // A timeout/cannot-complete response is ambiguous: the target may have applied
            // the write before the reply was lost. Never send Cmd+V after an ambiguous AX write.
            throw selectionReplacementError(
                code: 23,
                description: "The target did not acknowledge the selection replacement"
            )
        }
    }

    func validatedCurrentSelectionElement(
        context: SelectionContext,
        currentFrontmostProcessID: pid_t?,
        verifyClipboardText: Bool
    ) throws -> AXUIElement {
        guard Date().timeIntervalSince(context.capturedAt) <= Self.selectionContextLifetime else {
            throw selectionReplacementError(code: 26, description: "The captured selection expired")
        }
        guard let processID = context.processID,
              currentFrontmostProcessID == processID
        else {
            throw selectionReplacementError(
                code: 27,
                description: "The user moved away from the captured selection"
            )
        }

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, Self.replacementAXMessagingTimeout)
        AXUIElementSetMessagingTimeout(context.element, Self.replacementAXMessagingTimeout)

        guard var currentElement = lightweightFocusedElement(application: application) else {
            throw selectionReplacementError(code: 28, description: "The target no longer has a focused input")
        }
        AXUIElementSetMessagingTimeout(currentElement, Self.replacementAXMessagingTimeout)

        let currentText: String?
        if context.source == "clipboard-copy", verifyClipboardText {
            currentText = readSelectedTextViaCopy(
                processID: processID,
                milliseconds: Self.copySelectionTimeoutMilliseconds
            )
            guard let focusedAfterCopy = lightweightFocusedElement(application: application) else {
                throw selectionReplacementError(
                    code: 29,
                    description: "The selected text changed while the result was being generated"
                )
            }
            AXUIElementSetMessagingTimeout(focusedAfterCopy, Self.replacementAXMessagingTimeout)
            currentElement = focusedAfterCopy
        } else if context.source == "clipboard-copy" {
            currentText = context.selectedText
        } else {
            currentText = copyStringAttribute(kAXSelectedTextAttribute as String, from: currentElement)
        }
        let elementMatches = CFEqual(context.element, currentElement)
        let currentRange = copySelectedTextRange(from: currentElement)
        let currentRole = copyStringAttribute(kAXRoleAttribute as String, from: currentElement)
        let currentSubrole = copyStringAttribute(kAXSubroleAttribute as String, from: currentElement)
        let currentIdentifier = copyStringAttribute(kAXIdentifierAttribute as String, from: currentElement)
        let currentPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: currentElement)
        let currentSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: currentElement)
        let currentWindowTitle = lightweightWindowTitle(
            of: currentElement,
            fallbackProcessID: processID
        )

        guard Self.capturedSelectionStillMatches(
            source: context.source,
            elementMatches: elementMatches,
            capturedRange: context.range,
            currentRange: currentRange,
            capturedText: context.selectedText,
            currentText: currentText,
            capturedRole: context.role,
            currentRole: currentRole,
            capturedSubrole: context.subrole,
            currentSubrole: currentSubrole,
            capturedIdentifier: context.identifier,
            currentIdentifier: currentIdentifier,
            capturedPosition: context.position,
            currentPosition: currentPosition,
            capturedSize: context.size,
            currentSize: currentSize,
            capturedWindowTitle: context.windowTitle,
            currentWindowTitle: currentWindowTitle
        ) else {
            throw selectionReplacementError(
                code: 29,
                description: "The selected text changed while the result was being generated"
            )
        }

        return currentElement
    }

    func lightweightFocusedElement(application: AXUIElement) -> AXUIElement? {
        guard let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: application) else {
            return nil
        }
        guard copyStringAttribute(kAXRoleAttribute as String, from: focused) == kAXWindowRole as String else {
            return focused
        }
        return copyElementAttribute(kAXFocusedUIElementAttribute as String, from: focused) ?? focused
    }

    func lightweightWindowTitle(of element: AXUIElement, fallbackProcessID: pid_t?) -> String? {
        if let window = copyElementAttribute(kAXWindowAttribute as String, from: element) {
            AXUIElementSetMessagingTimeout(window, Self.replacementAXMessagingTimeout)
            if let title = copyTextAttribute(kAXTitleAttribute as String, from: window) {
                return title
            }
        }
        return focusedWindowTitle(for: fallbackProcessID)
    }

    func commitSelectionPaste(text: String, targetProcessID: pid_t?) async throws {
        let injector = UncheckedSendableReference(self)
        try await MainActor.run {
            try Task.checkCancellation()
            guard let targetProcessID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessID
            else {
                throw injector.value.selectionReplacementError(
                    code: 30,
                    description: "The user moved away from the captured selection"
                )
            }

            let source = CGEventSource(stateID: .combinedSessionState)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            else {
                throw injector.value.selectionReplacementError(
                    code: 25,
                    description: "Unable to create the paste shortcut"
                )
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand

            // All target validation has completed before the pasteboard changes.
            // After this point, dispatch immediately without another AX round-trip:
            // a rejected post-write validation would leave a failed transaction's
            // result on the user's clipboard.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw injector.value.selectionReplacementError(
                    code: 31,
                    description: "Unable to prepare the replacement text"
                )
            }
            keyDown.postToPid(targetProcessID)
            keyUp.postToPid(targetProcessID)
            NetworkDebugLogger.logMessage(
                "[Text Injection] selection transaction dispatched via eager paste"
            )
        }
    }

    func selectionReplacementError(code: Int, description: String) -> NSError {
        NSError(
            domain: "AXTextInjector.SelectionTransaction",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
