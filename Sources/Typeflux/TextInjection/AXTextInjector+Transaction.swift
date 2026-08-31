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
        capturedWindowTitle: String?,
        currentWindowTitle: String?
    ) -> Bool {
        if source == "clipboard-copy" {
            return elementMatches
        }

        guard capturedRange?.location == currentRange?.location,
              capturedRange?.length == currentRange?.length,
              capturedText == currentText
        else {
            return false
        }

        if elementMatches {
            return true
        }

        guard capturedRole == currentRole,
              let capturedWindowTitle = capturedWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              let currentWindowTitle = currentWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !capturedWindowTitle.isEmpty,
              capturedWindowTitle == currentWindowTitle
        else {
            return false
        }

        return true
    }

    func replaceSelection(text: String, target: TextSelectionSnapshot?) async throws {
        if target?.source == "typeflux-native" {
            try await MainActor.run {
                guard try self.insertIntoTypefluxNativeTextTarget(text, replaceSelection: true) else {
                    throw self.selectionReplacementError(
                        code: 20,
                        description: "The Typeflux selection is no longer available"
                    )
                }
                self.lastInjectionMethod = .ax
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

        let preparation = try await performSelectionReplacementWork {
            try self.prepareSelectionReplacement(text: text, context: context)
        }

        switch preparation {
        case .committedViaAX:
            lastInjectionMethod = .ax
        case .requiresPaste:
            try await prepareEagerPasteboard(text: text, targetProcessID: context.processID)
            try await performSelectionReplacementWork {
                try self.dispatchSelectionPaste(context: context)
            }
            lastInjectionMethod = .paste
        }

        latestSelectionContext = nil
    }

    func performSelectionReplacementWork<T>(
        _ work: @escaping () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            selectionReplacementQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func prepareSelectionReplacement(
        text: String,
        context: SelectionContext
    ) throws -> SelectionReplacementPreparation {
        let element = try validatedCurrentSelectionElement(context: context)

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

    func dispatchSelectionPaste(context: SelectionContext) throws {
        _ = try validatedCurrentSelectionElement(context: context)
        guard let processID = context.processID else {
            throw selectionReplacementError(code: 24, description: "The target application is unavailable")
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            throw selectionReplacementError(code: 25, description: "Unable to create the paste shortcut")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processID)
        keyUp.postToPid(processID)
        NetworkDebugLogger.logMessage(
            "[Text Injection] selection transaction dispatched via eager paste"
        )
    }

    func validatedCurrentSelectionElement(context: SelectionContext) throws -> AXUIElement {
        guard Date().timeIntervalSince(context.capturedAt) <= Self.selectionContextLifetime else {
            throw selectionReplacementError(code: 26, description: "The captured selection expired")
        }
        guard let processID = context.processID,
              frontmostProcessID() == processID
        else {
            throw selectionReplacementError(
                code: 27,
                description: "The user moved away from the captured selection"
            )
        }

        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, Self.replacementAXMessagingTimeout)
        AXUIElementSetMessagingTimeout(context.element, Self.replacementAXMessagingTimeout)

        guard let currentElement = lightweightFocusedElement(application: application) else {
            throw selectionReplacementError(code: 28, description: "The target no longer has a focused input")
        }
        AXUIElementSetMessagingTimeout(currentElement, Self.replacementAXMessagingTimeout)

        let elementMatches = CFEqual(context.element, currentElement)
        let currentRange = copySelectedTextRange(from: currentElement)
        let currentText = copyStringAttribute(kAXSelectedTextAttribute as String, from: currentElement)
        let currentRole = copyStringAttribute(kAXRoleAttribute as String, from: currentElement)
        let currentWindowTitle = lightweightWindowTitle(of: currentElement)

        guard Self.capturedSelectionStillMatches(
            source: context.source,
            elementMatches: elementMatches,
            capturedRange: context.range,
            currentRange: currentRange,
            capturedText: context.selectedText,
            currentText: currentText,
            capturedRole: context.role,
            currentRole: currentRole,
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

    func lightweightWindowTitle(of element: AXUIElement) -> String? {
        if let window = copyElementAttribute(kAXWindowAttribute as String, from: element) {
            AXUIElementSetMessagingTimeout(window, Self.replacementAXMessagingTimeout)
            return copyTextAttribute(kAXTitleAttribute as String, from: window)
        }
        return nil
    }

    func prepareEagerPasteboard(text: String, targetProcessID: pid_t?) async throws {
        try await MainActor.run {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessID else {
                throw self.selectionReplacementError(
                    code: 30,
                    description: "The user moved away from the captured selection"
                )
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw self.selectionReplacementError(
                    code: 31,
                    description: "Unable to prepare the replacement text"
                )
            }
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
