import AppKit
import ApplicationServices
import Foundation

final class SelectionReplacementCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw CancellationError()
        }
    }
}

extension AXTextInjector {
    enum SelectionEvidence: String, Equatable {
        case match
        case conflict
        case unavailable
    }

    struct SelectionFingerprintAssessment: Equatable {
        let accepted: Bool
        let text: SelectionEvidence
        let range: SelectionEvidence
        let role: SelectionEvidence
        let subrole: SelectionEvidence
        let identifier: SelectionEvidence
        let frame: SelectionEvidence
        let window: SelectionEvidence

        var diagnosticSummary: String {
            "accepted=\(accepted) text=\(text.rawValue) range=\(range.rawValue) "
                + "role=\(role.rawValue) subrole=\(subrole.rawValue) "
                + "identifier=\(identifier.rawValue) frame=\(frame.rawValue) "
                + "window=\(window.rawValue)"
        }
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
        windowElementMatches: Bool? = nil,
        capturedWindowPosition: CGPoint? = nil,
        currentWindowPosition: CGPoint? = nil,
        capturedWindowSize: CGSize? = nil,
        currentWindowSize: CGSize? = nil,
        capturedWindowTitle: String?,
        currentWindowTitle: String?
    ) -> Bool {
        selectionFingerprintAssessment(
            source: source,
            elementMatches: elementMatches,
            capturedRange: capturedRange,
            currentRange: currentRange,
            capturedText: capturedText,
            currentText: currentText,
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
            windowElementMatches: windowElementMatches,
            capturedWindowPosition: capturedWindowPosition,
            currentWindowPosition: currentWindowPosition,
            capturedWindowSize: capturedWindowSize,
            currentWindowSize: currentWindowSize,
            capturedWindowTitle: capturedWindowTitle,
            currentWindowTitle: currentWindowTitle
        ).accepted
    }

    static func selectionFingerprintAssessment(
        source: String,
        elementMatches: Bool,
        capturedRange: CFRange?,
        currentRange: CFRange?,
        capturedText: String?,
        currentText: String?,
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
        windowElementMatches: Bool?,
        capturedWindowPosition: CGPoint?,
        currentWindowPosition: CGPoint?,
        capturedWindowSize: CGSize?,
        currentWindowSize: CGSize?,
        capturedWindowTitle: String?,
        currentWindowTitle: String?
    ) -> SelectionFingerprintAssessment {
        let textEvidence = compare(capturedText, currentText)
        let rangeEvidence = source == "clipboard-copy"
            ? .unavailable
            : compareRange(capturedRange, currentRange)
        let roleEvidence = compareRoleCapability(capturedRole, currentRole)
        let subroleEvidence = compareNormalized(capturedSubrole, currentSubrole)
        let identifierEvidence = compareNormalized(capturedIdentifier, currentIdentifier)
        let frameEvidence = compareFrame(
            capturedPosition: capturedPosition,
            capturedSize: capturedSize,
            currentPosition: currentPosition,
            currentSize: currentSize
        )
        let windowEvidence = compareWindow(
            elementMatches: windowElementMatches,
            capturedPosition: capturedWindowPosition,
            capturedSize: capturedWindowSize,
            currentPosition: currentWindowPosition,
            currentSize: currentWindowSize,
            capturedTitle: capturedWindowTitle,
            currentTitle: currentWindowTitle
        )

        let semanticElementEvidence = [roleEvidence, subroleEvidence, identifierEvidence, frameEvidence]
        let hasElementConflict = roleEvidence == .conflict
            || (!elementMatches && semanticElementEvidence.dropFirst().contains(.conflict))
        let hasConflict = hasElementConflict
            || (!elementMatches && windowElementMatches == false && windowEvidence == .conflict)
        let hasStrongIdentityMatch = elementMatches
            || identifierEvidence == .match
            || frameEvidence == .match
        let nativeIdentityMatches = elementMatches || (
            roleEvidence == .match
                && (identifierEvidence == .match || frameEvidence == .match)
        )
        let rangeMatches = rangeEvidence == .match
            || (capturedRange == nil && currentRange == nil && elementMatches)
        let accepted = textEvidence == .match
            && (source == "clipboard-copy" || rangeMatches)
            && !hasConflict
            && (source == "clipboard-copy" ? hasStrongIdentityMatch : nativeIdentityMatches)

        return SelectionFingerprintAssessment(
            accepted: accepted,
            text: textEvidence,
            range: rangeEvidence,
            role: roleEvidence,
            subrole: subroleEvidence,
            identifier: identifierEvidence,
            frame: frameEvidence,
            window: windowEvidence
        )
    }

    private static func compare<T: Equatable>(_ captured: T?, _ current: T?) -> SelectionEvidence {
        guard let captured, let current else { return .unavailable }
        return captured == current ? .match : .conflict
    }

    private static func compareNormalized(_ captured: String?, _ current: String?) -> SelectionEvidence {
        compare(normalizedEvidence(captured), normalizedEvidence(current))
    }

    private static func compareRange(_ captured: CFRange?, _ current: CFRange?) -> SelectionEvidence {
        guard let captured, let current else { return .unavailable }
        return captured.location == current.location && captured.length == current.length ? .match : .conflict
    }

    private static func compareFrame(
        capturedPosition: CGPoint?,
        capturedSize: CGSize?,
        currentPosition: CGPoint?,
        currentSize: CGSize?
    ) -> SelectionEvidence {
        guard let capturedPosition, let capturedSize, let currentPosition, let currentSize else {
            return .unavailable
        }
        return capturedPosition == currentPosition && capturedSize == currentSize ? .match : .conflict
    }

    private static func compareRoleCapability(_ captured: String?, _ current: String?) -> SelectionEvidence {
        let captured = normalizedEvidence(captured)
        let current = normalizedEvidence(current)
        // Use the same capability classification as capture and dispatch. Opaque
        // containers also occur in the legacy non-editable-role list; consulting
        // that list directly would reject even an unchanged AXWindow selection.
        let isKnownNonWritable: (String) -> Bool = {
            targetCapability(role: $0, hasSelectedRange: false, hasSettableTextAttributes: false) == .notWritable
        }
        if captured.map(isKnownNonWritable) == true || current.map(isKnownNonWritable) == true {
            return .conflict
        }
        guard let captured, let current else { return .unavailable }
        if captured == current {
            return .match
        }
        let compatibleRoles = nativeEditableRoles.union(genericEditableRoles).union(opaqueContainerRoles)
        return compatibleRoles.contains(captured) && compatibleRoles.contains(current) ? .match : .conflict
    }

    private static func compareWindow(
        elementMatches: Bool?,
        capturedPosition: CGPoint?,
        capturedSize: CGSize?,
        currentPosition: CGPoint?,
        currentSize: CGSize?,
        capturedTitle: String?,
        currentTitle: String?
    ) -> SelectionEvidence {
        if elementMatches == true {
            return .match
        }
        let frame = compareFrame(
            capturedPosition: capturedPosition,
            capturedSize: capturedSize,
            currentPosition: currentPosition,
            currentSize: currentSize
        )
        let title = compareNormalized(capturedTitle, currentTitle)
        if frame == .conflict || title == .conflict {
            return .conflict
        }
        // A title is not unique enough to identify a window by itself. A stable
        // frame plus a non-conflicting title can identify a rebuilt AXWindow.
        if frame == .match {
            return .match
        }
        return elementMatches == false ? .conflict : .unavailable
    }

    private static func normalizedEvidence(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    func performSelectionReplacementWork<T>(
        _ work: @escaping () throws -> T
    ) async throws -> T {
        let cancellationToken = SelectionReplacementCancellationToken()
        return try await performSelectionReplacementWork(
            cancellationToken: cancellationToken,
            work
        )
    }

    func performSelectionReplacementWork<T>(
        cancellationToken: SelectionReplacementCancellationToken,
        _ work: @escaping () throws -> T
    ) async throws -> T {
        let sendableWork = UncheckedSendableReference(work)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                selectionReplacementQueue.async {
                    do {
                        try cancellationToken.checkCancellation()
                        continuation.resume(returning: try sendableWork.value())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellationToken.cancel()
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

        guard var currentElement = deliveryFocusedElement(for: processID) else {
            throw selectionReplacementError(code: 28, description: "The target no longer has a focused input")
        }
        AXUIElementSetMessagingTimeout(currentElement, Self.replacementAXMessagingTimeout)

        let currentText: String?
        if context.source == "clipboard-copy", verifyClipboardText {
            currentText = readSelectedTextViaCopy(
                processID: processID,
                milliseconds: Self.copySelectionTimeoutMilliseconds
            )
            guard let focusedAfterCopy = deliveryFocusedElement(for: processID) else {
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
            currentText = copyTextAttribute(kAXSelectedTextAttribute as String, from: currentElement)
        }
        let elementMatches = CFEqual(context.element, currentElement)
        let currentRange = copySelectedTextRange(from: currentElement)
        let currentRole = copyStringAttribute(kAXRoleAttribute as String, from: currentElement)
        let currentSubrole = copyStringAttribute(kAXSubroleAttribute as String, from: currentElement)
        let currentIdentifier = copyStringAttribute(kAXIdentifierAttribute as String, from: currentElement)
        let currentPosition = copyCGPointAttribute(kAXPositionAttribute as String, from: currentElement)
        let currentSize = copyCGSizeAttribute(kAXSizeAttribute as String, from: currentElement)
        let currentWindowElement = focusedWindowElement(for: processID) ?? containingWindow(of: currentElement)
        if let currentWindowElement {
            AXUIElementSetMessagingTimeout(currentWindowElement, Self.replacementAXMessagingTimeout)
        }
        let windowElementMatches: Bool? = if let capturedWindow = context.windowElement,
                                            let currentWindowElement {
            CFEqual(capturedWindow, currentWindowElement)
        } else {
            nil
        }
        let currentWindowPosition = currentWindowElement.flatMap {
            copyCGPointAttribute(kAXPositionAttribute as String, from: $0)
        }
        let currentWindowSize = currentWindowElement.flatMap {
            copyCGSizeAttribute(kAXSizeAttribute as String, from: $0)
        }
        let currentWindowTitle = lightweightWindowTitle(
            of: currentElement,
            fallbackProcessID: processID
        )

        let assessment = Self.selectionFingerprintAssessment(
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
            windowElementMatches: windowElementMatches,
            capturedWindowPosition: context.windowPosition,
            currentWindowPosition: currentWindowPosition,
            capturedWindowSize: context.windowSize,
            currentWindowSize: currentWindowSize,
            capturedWindowTitle: context.windowTitle,
            currentWindowTitle: currentWindowTitle
        )
        NetworkDebugLogger.logMessage(
            "[Text Injection] selection fingerprint \(assessment.diagnosticSummary) capturedRole=\(context.role ?? "unknown") currentRole=\(currentRole ?? "unknown")"
        )
        guard assessment.accepted else {
            throw selectionReplacementError(
                code: 29,
                description: "The selected text changed while the result was being generated"
            )
        }

        return currentElement
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

    func selectionReplacementError(code: Int, description: String) -> NSError {
        NSError(
            domain: "AXTextInjector.SelectionTransaction",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
