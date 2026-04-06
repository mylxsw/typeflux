import AppKit
import ApplicationServices
import Foundation
import os

final class AXTextInjector: TextInjector {
    private static let nativeEditableRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXComboBox",
        "AXSearchField",
    ]

    private static let genericEditableRoles: Set<String> = [
        "AXGroup",
        "AXWebArea",
        "AXUnknown",
    ]

    private static let nonEditableFalsePositiveRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXCloseButton",
        "AXColorWell",
        "AXColumn",
        "AXDisclosureTriangle",
        "AXDrawer",
        "AXGrid",
        "AXImage",
        "AXIncrementor",
        "AXLayoutArea",
        "AXLevelIndicator",
        "AXLink",
        "AXList",
        "AXMenuBar",
        "AXMenuBarItem",
        "AXMenuButton",
        "AXOutline",
        "AXPopUpButton",
        "AXProgressIndicator",
        "AXRadioButton",
        "AXRow",
        "AXRuler",
        "AXScrollArea",
        "AXScrollBar",
        "AXSheet",
        "AXSlider",
        "AXSplitGroup",
        "AXSplitter",
        "AXStaticText",
        "AXSwitch",
        "AXTabGroup",
        "AXTable",
        "AXToolbar",
        "AXValueIndicator",
        "AXWindow",
    ]

    struct FocusResolutionCandidate: Equatable {
        let role: String?
        let isEditable: Bool
        let isFocused: Bool?
        let selectedRange: CFRange?

        static func == (lhs: FocusResolutionCandidate, rhs: FocusResolutionCandidate) -> Bool {
            lhs.role == rhs.role &&
                lhs.isEditable == rhs.isEditable &&
                lhs.isFocused == rhs.isFocused &&
                lhs.selectedRange?.location == rhs.selectedRange?.location &&
                lhs.selectedRange?.length == rhs.selectedRange?.length
        }
    }

    private let logger = Logger(subsystem: "dev.typeflux", category: "AXTextInjector")
    private let settingsStore: SettingsStore?
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
    private static let legacyPasteRestoreDelayNanoseconds: UInt64 = 500_000_000
    private static let verifiedPasteRestoreDelayNanoseconds: UInt64 = 1_500_000_000
    private static let pasteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    private static let pasteVerificationAttempts = 4
    private static let axWriteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    private static let axWriteVerificationAttempts = 4
    private static let focusRestoreDelayMicroseconds: useconds_t = 250_000
    private static let selectedTextTimeoutMilliseconds = 200
    private static let copySelectionTimeoutMilliseconds = 180
    private static let copyShortcutKeyCode: CGKeyCode = 8
    private static let selectionContextLifetime: TimeInterval = 180
    private static let focusedDescendantSearchDepth = 6

    private var latestSelectionContext: SelectionContext?

    enum PasteVerificationResult: Equatable {
        case success
        case failure(String)
        case indeterminate
    }

    static func shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
        replaceSelection: Bool,
        selectionSource: String?,
        focusMatched: Bool,
        baselineAvailable: Bool
    ) -> Bool {
        guard replaceSelection, !baselineAvailable else { return false }
        return selectionSource == "clipboard-copy" && focusMatched
    }

    static func shouldPreferEditableDescendant(
        overWindowRole role: String?,
        candidate: FocusResolutionCandidate?
    ) -> Bool {
        guard role == "AXWindow", let candidate else { return false }
        guard candidate.isEditable else { return false }
        guard candidate.isFocused != true else { return false }
        guard editableCandidateScore(for: candidate) > 0 else { return false }

        if let selectedRange = candidate.selectedRange {
            return selectedRange.location >= 0 && selectedRange.length >= 0
        }

        // Fallback for editable descendants that expose editability but omit selection range.
        return Self.nativeEditableRoles.contains(candidate.role ?? "")
            || Self.genericEditableRoles.contains(candidate.role ?? "")
    }

    static func shouldTreatAXValueAsUnreadable(
        role: String?,
        value: String,
        selectedRange: CFRange?
    ) -> Bool {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedValue.isEmpty else { return false }
        guard !Self.nativeEditableRoles.contains(role ?? "") else { return false }

        // Generic AX containers in web/electron apps often expose an empty AXValue even when
        // the actual editor content is not readable through accessibility APIs. Treat those as
        // unreadable so verification does not incorrectly conclude that the text is unchanged.
        return selectedRange != nil || role == "AXGroup" || role == "AXWebArea" || role == "AXUnknown"
    }

    static func editableCandidateScore(for candidate: FocusResolutionCandidate) -> Int {
        guard candidate.isEditable else { return 0 }

        let role = candidate.role ?? "AXUnknown"
        if nonEditableFalsePositiveRoles.contains(role) {
            return 0
        }

        var score = 1

        if nativeEditableRoles.contains(role) {
            score += 5
        } else if genericEditableRoles.contains(role) {
            score += 3
        } else {
            return 0
        }

        if let selectedRange = candidate.selectedRange,
           selectedRange.location >= 0,
           selectedRange.length >= 0
        {
            score += 4
        }

        if candidate.isFocused == true {
            score += 2
        }

        return score
    }

    init(settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore
    }

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
                isFocusedTarget: false,
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
                isFocusedTarget: result.context.isFocusedTarget,
            )
        }
        logger.debug("ax-api returned nil — trying clipboard-copy")

        if let copiedText = readSelectedTextViaCopy(processID: processID, milliseconds: Self.copySelectionTimeoutMilliseconds) {
            let focusedElement = focusedElement()
            let focusedWindow = processID.flatMap(focusedWindowElement(for:))
            let selectionWindow = focusedElement.flatMap(containingWindow(of:))
            let editability = focusedElement.map(isLikelyEditable(element:)) ?? false
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
                capturedAt: Date(),
            )
            latestSelectionContext = context
            logger.debug("source=clipboard-copy  focusedWindow=\(focusedWindow != nil ? "present" : "nil", privacy: .public)  selectionWindow=\(selectionWindow != nil ? "present" : "nil", privacy: .public)  isFocusedTarget=\(isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(copiedText.prefix(32)), privacy: .public)")
            // Cmd+C proves that text is currently selected. Editability still comes from
            // the focused element. This path is replaceable when the target is editable,
            // but it is not safe to treat it as restorable selection state.
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                selectedRange: nil,
                selectedText: copiedText,
                source: "clipboard-copy",
                isEditable: editability,
                role: nil,
                windowTitle: context.windowTitle,
                isFocusedTarget: context.isFocusedTarget,
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
            isFocusedTarget: false,
        )
    }

    func insert(text: String) throws {
        try setText(text, replaceSelection: false)
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        readCurrentInputTextSnapshot()
    }

    private func readCurrentInputTextSnapshot() -> CurrentInputTextSnapshot {
        guard AXIsProcessTrusted() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                role: nil,
                text: nil,
                isEditable: false,
                failureReason: "accessibility-not-trusted",
            )
        }

        guard let element = focusedElement() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                role: nil,
                text: nil,
                isEditable: false,
                failureReason: "no-focused-element",
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isEditable = isLikelyEditable(element: element)
        let selectedRange = copySelectedTextRange(from: element)

        guard isEditable else {
            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                role: role,
                text: nil,
                isEditable: false,
                failureReason: "focused-element-not-editable",
            )
        }

        if let value = copyTextAttribute(kAXValueAttribute as String, from: element) {
            if Self.shouldTreatAXValueAsUnreadable(role: role, value: value, selectedRange: selectedRange) {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    role: role,
                    text: nil,
                    isEditable: true,
                    failureReason: "missing-ax-value",
                )
            }
            if let placeholder = copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element), placeholder == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    role: role,
                    text: nil,
                    isEditable: true,
                    failureReason: "value-matched-placeholder",
                )
            }
            if let title = copyTextAttribute(kAXTitleAttribute as String, from: element), title == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    role: role,
                    text: nil,
                    isEditable: true,
                    failureReason: "value-matched-title",
                )
            }

            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                role: role,
                text: value,
                isEditable: true,
                failureReason: nil,
            )
        }

        return CurrentInputTextSnapshot(
            processID: processID,
            processName: processName,
            role: role,
            text: nil,
            isEditable: true,
            failureReason: "missing-ax-value",
        )
    }

    func currentInputText() async -> String? {
        await currentInputTextSnapshot().text
    }

    func replaceSelection(text: String) throws {
        try setText(text, replaceSelection: true)
    }

    private func selectionContextSummary(_ context: SelectionContext?) -> String {
        guard let context else { return "<nil>" }
        let range = context.range.map { "[\($0.location),\($0.length)]" } ?? "nil"
        return "pid=\(context.processID.map(String.init) ?? "nil") process=\(context.processName ?? "nil") role=\(context.role ?? "nil") window=\(context.windowTitle ?? "nil") source=\(context.source) focused=\(context.isFocusedTarget) range=\(range)"
    }

    private func snapshotSummary(_ snapshot: CurrentInputTextSnapshot) -> String {
        let preview = snapshot.text.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) } ?? "nil"
        return "pid=\(snapshot.processID.map(String.init) ?? "nil") process=\(snapshot.processName ?? "nil") role=\(snapshot.role ?? "nil") editable=\(snapshot.isEditable) failure=\(snapshot.failureReason ?? "nil") textLength=\(snapshot.text?.count ?? 0) preview=\(preview)"
    }

    private func elementSummary(_ element: AXUIElement) -> String {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element) ?? "nil"
        let subrole = copyStringAttribute(kAXSubroleAttribute as String, from: element) ?? "nil"
        let title = copyTextAttribute(kAXTitleAttribute as String, from: element) ?? "nil"
        let description = copyTextAttribute(kAXDescriptionAttribute as String, from: element) ?? "nil"
        let value = copyTextAttribute(kAXValueAttribute as String, from: element)
        let placeholder = copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element)
        let focused = copyBooleanAttribute(kAXFocusedAttribute as String, from: element).map(String.init) ?? "nil"
        let editable = isLikelyEditable(element: element)
        let selectedRange = copySelectedTextRange(from: element).map { "[\($0.location),\($0.length)]" } ?? "nil"
        let valuePreview = value.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) } ?? "nil"
        let placeholderPreview = placeholder.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) } ?? "nil"

        return "role=\(role) subrole=\(subrole) focused=\(focused) editable=\(editable) selectedRange=\(selectedRange) title=\(title) description=\(description) valuePreview=\(valuePreview) placeholderPreview=\(placeholderPreview)"
    }

    private func focusResolutionCandidate(for element: AXUIElement) -> FocusResolutionCandidate {
        FocusResolutionCandidate(
            role: copyStringAttribute(kAXRoleAttribute as String, from: element),
            isEditable: isLikelyEditable(element: element),
            isFocused: copyBooleanAttribute(kAXFocusedAttribute as String, from: element),
            selectedRange: copySelectedTextRange(from: element),
        )
    }

    private func subtreeSummary(of element: AXUIElement, depthRemaining: Int, maxChildren: Int = 8) -> [String] {
        guard depthRemaining >= 0 else { return [] }

        var lines: [String] = [elementSummary(element)]
        guard depthRemaining > 0 else { return lines }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        if children.isEmpty {
            return lines
        }

        for (index, child) in children.prefix(maxChildren).enumerated() {
            let childLines = subtreeSummary(of: child, depthRemaining: depthRemaining - 1, maxChildren: maxChildren)
            lines.append(contentsOf: childLines.map { "child[\(index)] " + $0 })
        }

        if children.count > maxChildren {
            lines.append("child[+] truncated additionalChildren=\(children.count - maxChildren)")
        }

        return lines
    }

    private func findBestEditableDescendant(
        in element: AXUIElement,
        depthRemaining: Int,
    ) -> AXUIElement? {
        guard depthRemaining >= 0 else { return nil }

        let children = copyElementArrayAttribute(kAXChildrenAttribute as String, from: element)
        var bestElement: AXUIElement?
        var bestScore = 0

        for child in children {
            let candidate = focusResolutionCandidate(for: child)
            let score = Self.editableCandidateScore(for: candidate)
            if score > bestScore {
                bestScore = score
                bestElement = child
            }

            guard depthRemaining > 0,
                  let nested = findBestEditableDescendant(in: child, depthRemaining: depthRemaining - 1)
            else {
                continue
            }

            let nestedCandidate = focusResolutionCandidate(for: nested)
            let nestedScore = Self.editableCandidateScore(for: nestedCandidate)
            if nestedScore > bestScore {
                bestScore = nestedScore
                bestElement = nested
            }
        }

        return bestElement
    }

    private func logFocusResolution(context: String, rootElement: AXUIElement, resolvedElement: AXUIElement?) {
        let resolvedSummary = resolvedElement.map(elementSummary) ?? "<nil>"
        let editableCandidate = findBestEditableDescendant(
            in: rootElement,
            depthRemaining: Self.focusedDescendantSearchDepth,
        )
        let editableCandidateSummary = editableCandidate.map(elementSummary) ?? "<nil>"
        let tree = subtreeSummary(of: rootElement, depthRemaining: 2).joined(separator: "\n")
        NetworkDebugLogger.logMessage(
            """
            [Focus Resolution] \(context)
            root: \(elementSummary(rootElement))
            resolved: \(resolvedSummary)
            bestEditableDescendant: \(editableCandidateSummary)
            subtree:
            \(tree)
            """
        )
    }

    private func focusedElement() -> AXUIElement? {
        if let processID = frontmostProcessID(),
           let focused = focusedElement(for: processID)
        {
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
        let isNativeText = Self.nativeEditableRoles.contains(role ?? "")

        let isSettable = isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)

        if !isNativeText, !isSettable {
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
        if range == nil, role == "AXWebArea" || role == "AXGroup" || role == "AXUnknown" {
            if let value = copyStringAttribute(kAXValueAttribute as String, from: element), value == text {
                return nil
            }
        }

        guard let range else { return nil }

        let processID = frontmostProcessID()
        let focusedWindow = processID.flatMap(focusedWindowElement(for:))
        let selectionWindow = containingWindow(of: element)
        let isFocusedTarget = focusedWindow.map { w in
            selectionWindow.map { s in windowsMatch(w, s) } ?? true
        } ?? false

        let context = SelectionContext(
            element: element,
            range: range,
            processID: processID,
            processName: frontmostApplicationName(),
            role: role,
            windowTitle: selectionWindow.flatMap(windowTitle(of:)),
            isFocusedTarget: isFocusedTarget,
            source: "accessibility",
            capturedAt: Date(),
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
        let selectedRange = copySelectedTextRange(from: element)

        if Self.nativeEditableRoles.contains(role ?? "") {
            return true
        }

        if let role, Self.nonEditableFalsePositiveRoles.contains(role) {
            return false
        }

        let hasSettableTextAttributes = isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            || isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)

        if Self.genericEditableRoles.contains(role ?? "") {
            return selectedRange != nil || hasSettableTextAttributes
        }

        return selectedRange != nil && hasSettableTextAttributes
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
                userInfo: [NSLocalizedDescriptionKey: "Accessibility permission required"],
            )
        }

        var contextRestored = false
        let beforeSnapshot = readCurrentInputTextSnapshot()
        NetworkDebugLogger.logMessage(
            """
            [Text Injection] start
            replaceSelection: \(replaceSelection)
            textLength: \(text.count)
            textPreview: \(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
            beforeSnapshot: \(snapshotSummary(beforeSnapshot))
            activeSelectionContext: \(selectionContextSummary(activeSelectionContext()))
            """
        )

        if replaceSelection,
           let context = activeSelectionContext()
        {
            NetworkDebugLogger.logMessage("[Text Injection] restoring selection context before replace | \(selectionContextSummary(context))")
            restoreSelectionContext(context)
            contextRestored = true
            if context.range != nil,
               try insertTextViaAX(
                   text,
                   into: context.element,
                   replaceSelection: true,
                   selectionRange: context.range,
                   beforeSnapshot: beforeSnapshot,
               )
            {
                NetworkDebugLogger.logMessage("[Text Injection] replace completed via AX selected-text write")
                latestSelectionContext = nil
                return
            }
            NetworkDebugLogger.logMessage("[Text Injection] AX selected-text write unavailable or unverified, falling back")
        }

        if let element = focusedElement(), try insertTextViaAX(
            text,
            into: element,
            replaceSelection: replaceSelection,
            selectionRange: nil,
            beforeSnapshot: beforeSnapshot,
        ) {
            NetworkDebugLogger.logMessage("[Text Injection] completed via focused AX path")
            if replaceSelection {
                latestSelectionContext = nil
            }
            return
        }

        NetworkDebugLogger.logMessage("[Text Injection] falling back to paste path")
        try setTextViaPaste(text, replaceSelection: replaceSelection, contextAlreadyRestored: contextRestored)
        if replaceSelection {
            latestSelectionContext = nil
        }
        NetworkDebugLogger.logMessage("[Text Injection] paste path completed")
    }

    private func insertTextViaAX(
        _ text: String,
        into element: AXUIElement,
        replaceSelection: Bool,
        selectionRange: CFRange?,
        beforeSnapshot: CurrentInputTextSnapshot,
    ) throws -> Bool {
        if replaceSelection {
            if let selectionRange {
                _ = setSelectedTextRange(selectionRange, on: element)
            }
            let replaceSelectedText = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef,
            )
            if replaceSelectedText == .success {
                if verifyAXWriteApplied(
                    insertedText: text,
                    replaceSelection: true,
                    targetProcessID: frontmostProcessID(),
                    beforeSnapshot: beforeSnapshot,
                ) {
                    return true
                }
                let afterSnapshot = readCurrentInputTextSnapshot()
                logger.debug("AX selected text write reported success but could not be verified; falling back")
                NetworkDebugLogger.logMessage(
                    """
                    [Text Injection] AX write verification failed
                    replaceSelection: \(replaceSelection)
                    beforeSnapshot: \(snapshotSummary(beforeSnapshot))
                    afterSnapshot: \(snapshotSummary(afterSnapshot))
                    """
                )
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

    private func verifyAXWriteApplied(
        insertedText: String,
        replaceSelection: Bool,
        targetProcessID: pid_t?,
        beforeSnapshot: CurrentInputTextSnapshot,
    ) -> Bool {
        for attempt in 0 ..< Self.axWriteVerificationAttempts {
            usleep(Self.axWriteVerificationPollIntervalMicroseconds)
            let afterSnapshot = readCurrentInputTextSnapshot()
            let verification = Self.evaluatePasteVerification(
                insertedText: insertedText,
                replaceSelection: replaceSelection,
                targetProcessID: targetProcessID,
                before: beforeSnapshot.isEditable ? beforeSnapshot : nil,
                after: afterSnapshot,
            )
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] AX verification attempt \(attempt + 1)
                result: \(String(describing: verification))
                beforeSnapshot: \(snapshotSummary(beforeSnapshot))
                afterSnapshot: \(snapshotSummary(afterSnapshot))
                """
            )

            switch verification {
            case .success:
                return true
            case .failure:
                return false
            case .indeterminate:
                continue
            }
        }

        return false
    }

    private func setTextViaPaste(_ text: String, replaceSelection: Bool, contextAlreadyRestored: Bool = false) throws {
        let pasteboard = NSPasteboard.general
        let previousSnapshot = capturePasteboardSnapshot(from: pasteboard)
        let targetPID: pid_t?
        let beforeSnapshot: CurrentInputTextSnapshot?
        let strictFallbackEnabled = settingsStore?.strictEditApplyFallbackEnabled ?? false
        let replacementContext = replaceSelection ? activeSelectionContext() : nil

        if let context = replacementContext {
            targetPID = context.processID
            if !contextAlreadyRestored {
                restoreSelectionContext(context)
            }
        } else {
            targetPID = frontmostProcessID()
        }

        let initialSnapshot = readCurrentInputTextSnapshot()
        beforeSnapshot = initialSnapshot.isEditable ? initialSnapshot : nil
        let allowClipboardSelectionReplacementWithoutAXBaseline = Self.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
            replaceSelection: replaceSelection,
            selectionSource: replacementContext?.source,
            focusMatched: replacementContext?.isFocusedTarget ?? false,
            baselineAvailable: beforeSnapshot != nil,
        )
        NetworkDebugLogger.logMessage(
            """
            [Text Injection] paste start
            replaceSelection: \(replaceSelection)
            strictFallbackEnabled: \(strictFallbackEnabled)
            targetPID: \(targetPID.map(String.init) ?? "nil")
            contextAlreadyRestored: \(contextAlreadyRestored)
            initialSnapshot: \(snapshotSummary(initialSnapshot))
            verificationBaseline: \(beforeSnapshot.map(snapshotSummary) ?? "<nil>")
            allowClipboardSelectionReplacementWithoutAXBaseline: \(allowClipboardSelectionReplacementWithoutAXBaseline)
            """
        )

        if replaceSelection, strictFallbackEnabled, beforeSnapshot == nil, !allowClipboardSelectionReplacementWithoutAXBaseline {
            NetworkDebugLogger.logMessage("[Text Injection] paste aborted because replacement target is not verifiable")
            throw NSError(
                domain: "AXTextInjector",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Replacement target is not a verifiable editable input.",
                ],
            )
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

        if allowClipboardSelectionReplacementWithoutAXBaseline {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste verification skipped because clipboard-backed selection cannot provide AX baseline",
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds,
            )
            return
        }

        guard strictFallbackEnabled else {
            NetworkDebugLogger.logMessage("[Text Injection] paste verification skipped because strict fallback is disabled")
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.legacyPasteRestoreDelayNanoseconds,
            )
            return
        }

        var lastFailureReason: String?
        for attempt in 0 ..< Self.pasteVerificationAttempts {
            usleep(Self.pasteVerificationPollIntervalMicroseconds)
            let afterSnapshot = readCurrentInputTextSnapshot()
            let verification = Self.evaluatePasteVerification(
                insertedText: text,
                replaceSelection: replaceSelection,
                targetProcessID: targetPID,
                before: beforeSnapshot,
                after: afterSnapshot,
            )
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] paste verification attempt \(attempt + 1)
                result: \(String(describing: verification))
                baseline: \(beforeSnapshot.map(snapshotSummary) ?? "<nil>")
                afterSnapshot: \(snapshotSummary(afterSnapshot))
                """
            )

            switch verification {
            case .success:
                restorePasteboardAfterPaste(
                    previousSnapshot,
                    delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds,
                )
                return
            case let .failure(reason):
                lastFailureReason = reason
                logger.debug(
                    "paste verification failed on attempt \(attempt + 1, privacy: .public): \(reason, privacy: .public)",
                )
            case .indeterminate:
                logger.debug(
                    "paste verification indeterminate on attempt \(attempt + 1, privacy: .public)",
                )
            }
        }

        restorePasteboardAfterPaste(
            previousSnapshot,
            delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds,
        )

        if let lastFailureReason {
            let finalSnapshot = readCurrentInputTextSnapshot()
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] paste verification exhausted
                lastFailureReason: \(lastFailureReason)
                finalSnapshot: \(snapshotSummary(finalSnapshot))
                """
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Paste insertion could not be verified: \(lastFailureReason)",
                ],
            )
        }
    }

    static func evaluatePasteVerification(
        insertedText: String,
        replaceSelection: Bool,
        targetProcessID: pid_t?,
        before: CurrentInputTextSnapshot?,
        after: CurrentInputTextSnapshot,
    ) -> PasteVerificationResult {
        let normalizedInsertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let targetProcessID, let afterProcessID = after.processID, targetProcessID != afterProcessID {
            return .failure("focused-process-changed")
        }

        if let reason = after.failureReason, reason == "no-focused-element" {
            return .failure(reason)
        }

        if let afterText = after.text {
            let normalizedAfterText = afterText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !normalizedInsertedText.isEmpty, normalizedAfterText.contains(normalizedInsertedText) {
                return .success
            }

            if let beforeText = before?.text {
                let normalizedBeforeText = beforeText.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalizedBeforeText == normalizedAfterText {
                    return .failure("input-text-unchanged")
                }
            } else if replaceSelection, !normalizedInsertedText.isEmpty, normalizedAfterText != normalizedInsertedText {
                return .indeterminate
            }
        }

        if let reason = after.failureReason,
           reason == "focused-element-not-editable" || reason == "accessibility-not-trusted"
        {
            // Some apps accept Cmd+V into a web/editor surface while AX still reports the window
            // container instead of a readable text field. In plain insertion mode, treat that as
            // unverifiable rather than a hard failure so we don't incorrectly show the copy dialog.
            if !replaceSelection, before == nil {
                return .indeterminate
            }
            return .failure(reason)
        }

        return .indeterminate
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
            axRange,
        )
        return result == .success
    }

    @discardableResult
    private func setFocused(_ focused: Bool, on element: AXUIElement) -> Bool {
        let value: CFBoolean = focused ? true as CFBoolean : false as CFBoolean
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            value,
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
           let resolved = resolveFocusedElement(focused)
        {
            logFocusResolution(context: "systemFocusedElement", rootElement: focused, resolvedElement: resolved)
            return resolved
        }

        return nil
    }

    private func focusedElement(for processID: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processID)

        if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focused)
        {
            logFocusResolution(context: "focusedElement(appFocusedUIElement)", rootElement: focused, resolvedElement: resolved)
            return resolved
        }

        if let focusedWindow = copyElementAttribute(kAXFocusedWindowAttribute as String, from: appElement),
           let resolved = resolveFocusedElement(focusedWindow)
        {
            logFocusResolution(context: "focusedElement(focusedWindow)", rootElement: focusedWindow, resolvedElement: resolved)
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
           let resolved = resolveFocusedElement(nestedFocused)
        {
            return resolved
        }

        if let descendant = findFocusedDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth,
        ) {
            return descendant
        }

        if let editableDescendant = findBestEditableDescendant(
            in: element,
            depthRemaining: Self.focusedDescendantSearchDepth,
        ) {
            let candidate = focusResolutionCandidate(for: editableDescendant)
            NetworkDebugLogger.logMessage(
                """
                [Focus Resolution] no focused descendant found; editable descendant exists
                window: \(elementSummary(element))
                editableDescendant: \(elementSummary(editableDescendant))
                """
            )
            if Self.shouldPreferEditableDescendant(overWindowRole: role, candidate: candidate) {
                NetworkDebugLogger.logMessage(
                    """
                    [Focus Resolution] promoting editable descendant as focused target
                    window: \(elementSummary(element))
                    promotedDescendant: \(elementSummary(editableDescendant))
                    """
                )
                return editableDescendant
            }
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
                restorePasteboardAfterPaste(
                    previousSnapshot,
                    delayNanoseconds: Self.legacyPasteRestoreDelayNanoseconds,
                )
                let trimmed = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty == false) ? trimmed : nil
            }
            usleep(10000)
        }

        restorePasteboardAfterPaste(
            previousSnapshot,
            delayNanoseconds: Self.legacyPasteRestoreDelayNanoseconds,
        )
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
           let app = NSRunningApplication(processIdentifier: processID)
        {
            app.activate(options: [.activateIgnoringOtherApps])

            // Wait for the target app to actually become frontmost.
            // Some apps (WeChat, Sublime Text, Electron) need extra time.
            let deadline = Date().addingTimeInterval(0.8)
            var activated = false
            while Date() < deadline {
                usleep(50000) // 50ms per check
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

    private func restorePasteboardAfterPaste(
        _ previousSnapshot: PasteboardSnapshot,
        delayNanoseconds: UInt64,
    ) {
        Task.detached {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                self.restorePasteboard(previousSnapshot, to: pasteboard)
            }
        }
    }
}
