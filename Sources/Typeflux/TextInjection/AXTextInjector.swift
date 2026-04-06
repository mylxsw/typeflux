// swiftlint:disable file_length type_body_length
import AppKit
import ApplicationServices
import Foundation
import os

final class AXTextInjector: TextInjector {
    static let nativeEditableRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXComboBox",
        "AXSearchField",
    ]

    static let genericEditableRoles: Set<String> = [
        "AXGroup",
        "AXWebArea",
        "AXUnknown",
    ]

    static let nonEditableFalsePositiveRoles: Set<String> = [
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

    let logger = Logger(subsystem: "dev.typeflux", category: "AXTextInjector")
    let settingsStore: SettingsStore?
    struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    struct SelectionContext {
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

    static var didRequestAccessibility = false
    static let legacyPasteRestoreDelayNanoseconds: UInt64 = 150_000_000
    static let verifiedPasteRestoreDelayNanoseconds: UInt64 = 150_000_000
    static let pasteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    static let pasteVerificationAttempts = 4
    static let axWriteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    static let axWriteVerificationAttempts = 4
    static let focusRestoreDelayMicroseconds: useconds_t = 250_000
    static let selectedTextTimeoutMilliseconds = 200
    static let copySelectionTimeoutMilliseconds = 180
    static let copyShortcutKeyCode: CGKeyCode = 8
    static let selectionContextLifetime: TimeInterval = 180
    static let focusedDescendantSearchDepth = 6

    var latestSelectionContext: SelectionContext?

    enum PasteVerificationResult: Equatable {
        case success
        case failure(String)
        case indeterminate
    }

    static func shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
        replaceSelection: Bool,
        selectionSource: String?,
        focusMatched: Bool,
        baselineAvailable: Bool,
    ) -> Bool {
        guard replaceSelection, !baselineAvailable else { return false }
        return selectionSource == "clipboard-copy" && focusMatched
    }

    static func shouldPreferEditableDescendant(
        overWindowRole role: String?,
        candidate: FocusResolutionCandidate?,
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
        selectedRange: CFRange?,
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

    func readCurrentInputTextSnapshot() -> CurrentInputTextSnapshot {
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

    func selectionContextSummary(_ context: SelectionContext?) -> String {
        guard let context else { return "<nil>" }
        let range = context.range.map { "[\($0.location),\($0.length)]" } ?? "nil"
        return
            "pid=\(context.processID.map(String.init) ?? "nil") process=\(context.processName ?? "nil") "
                + "role=\(context.role ?? "nil") window=\(context.windowTitle ?? "nil") "
                + "source=\(context.source) focused=\(context.isFocusedTarget) range=\(range)"
    }

    func snapshotSummary(_ snapshot: CurrentInputTextSnapshot) -> String {
        let preview = snapshot.text.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        } ?? "nil"
        return
            "pid=\(snapshot.processID.map(String.init) ?? "nil") process=\(snapshot.processName ?? "nil") "
                + "role=\(snapshot.role ?? "nil") editable=\(snapshot.isEditable) "
                + "failure=\(snapshot.failureReason ?? "nil") textLength=\(snapshot.text?.count ?? 0) "
                + "preview=\(preview)"
    }

    func elementSummary(_ element: AXUIElement) -> String {
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

        return
            "role=\(role) subrole=\(subrole) focused=\(focused) editable=\(editable) "
                + "selectedRange=\(selectedRange) title=\(title) description=\(description) "
                + "valuePreview=\(valuePreview) placeholderPreview=\(placeholderPreview)"
    }
}
