// swiftlint:disable file_length function_body_length identifier_name line_length trailing_comma type_body_length
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

    let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "AXTextInjector")
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

    enum PasteDispatchMethod: Equatable {
        case postToPid
        case hidTap
    }

    /// When enabled, we re-activate the target process if it is not currently the
    /// frontmost app, so that panel-style windows (Alfred, Raycast, Warp/iTerm2
    /// hotkey windows, ...) remain key and the synthesized Cmd+V reaches the
    /// correct window.
    static func shouldActivateTargetBeforePaste(
        flagEnabled: Bool,
        targetProcessID: pid_t?,
        frontmostProcessID: pid_t?,
    ) -> Bool {
        guard flagEnabled, let target = targetProcessID else { return false }
        return target != frontmostProcessID
    }

    /// Chromium-based apps (Arc, Chrome, Edge, Electron) reset their keyboard
    /// focus to the window's default control (the URL bar) when they receive
    /// an `activate` call while already frontmost. Skipping the redundant
    /// activation keeps the original editable focus intact so the subsequent
    /// AX write / paste lands in the correct field. Apps that are *not*
    /// frontmost still need activation so their window accepts our keystrokes.
    static func shouldReactivateProcessForSelectionRestore(
        targetProcessID: pid_t?,
        frontmostProcessID: pid_t?,
    ) -> Bool {
        guard let target = targetProcessID else { return false }
        return target != frontmostProcessID
    }

    /// When the stubborn-paste flag is on, route Cmd+V through the HID tap so the
    /// event behaves like a real physical keystroke and survives non-standard
    /// event pipelines (Electron, NSPanel hotkey windows, etc.). Otherwise keep
    /// the process-scoped delivery that has been the default.
    static func pasteEventDispatchMethod(
        flagEnabled: Bool,
        targetProcessID: pid_t?,
    ) -> PasteDispatchMethod {
        if flagEnabled {
            return .hidTap
        }
        return targetProcessID != nil ? .postToPid : .hidTap
    }

    /// Strict paste verification is scoped to edit-apply (replace selection)
    /// flows, where a silently failed replacement must be surfaced so the user
    /// can copy the result manually. Plain insertions (voice dictation) cannot
    /// be reliably verified through AX on apps like WeChat, Warp, Codex,
    /// terminals, and the Safari address bar — their AXValue does not reflect
    /// the paste in time, which would produce a false-positive "copy result"
    /// dialog even when the paste visibly succeeded.
    static func shouldPerformStrictPasteVerification(
        replaceSelection: Bool,
        strictFallbackEnabled: Bool,
    ) -> Bool {
        strictFallbackEnabled && replaceSelection
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

    func performAXReadOnMainActor<T: Sendable>(
        _ body: @escaping @MainActor () -> T,
    ) async -> T {
        await MainActor.run {
            body()
        }
    }

    func performAXOperationOnMainThread<T>(
        _ body: () throws -> T,
    ) rethrows -> T {
        if Thread.isMainThread {
            return try body()
        }

        return try DispatchQueue.main.sync {
            try body()
        }
    }

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        await performAXReadOnMainActor {
            self.readSelectionSnapshot()
        }
    }

    func readSelectionSnapshot() -> TextSelectionSnapshot {
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
                bundleIdentifier: frontmostApplicationBundleIdentifier(),
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
        let bundleIdentifier = frontmostApplicationBundleIdentifier()
        logger.debug("getSelectionSnapshot — app: \(processName ?? "?", privacy: .public) (pid: \(processID.map(String.init) ?? "?", privacy: .public))")

        if let result = readSelectedText() {
            // Compute editability from the SAME element that produced the text,
            // avoiding a race where a second focusedElement() call returns a different element.
            let editability = isLikelyEditable(element: result.context.element)
            latestSelectionContext = result.context
            logger.debug("source=ax-api  role=\(result.context.role ?? "nil", privacy: .public)  range=\(result.context.range.map { "[\($0.location),\($0.length)]" } ?? "nil", privacy: .public)  isEditable=\(editability ? "true" : "false", privacy: .public)  isFocusedTarget=\(result.context.isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(result.text.prefix(32)), privacy: .public)")
            return TextSelectionSnapshot(
                processID: result.context.processID,
                processName: result.context.processName,
                bundleIdentifier: bundleIdentifier,
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
                bundleIdentifier: bundleIdentifier,
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
            bundleIdentifier: bundleIdentifier,
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
        try performAXOperationOnMainThread {
            try self.setText(text, replaceSelection: false)
        }
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        await performAXReadOnMainActor {
            self.readCurrentInputTextSnapshot()
        }
    }

    func readCurrentInputTextSnapshot() -> CurrentInputTextSnapshot {
        guard AXIsProcessTrusted() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                bundleIdentifier: frontmostApplicationBundleIdentifier(),
                role: nil,
                text: nil,
                isEditable: false,
                isFocusedTarget: false,
                failureReason: "accessibility-not-trusted",
            )
        }

        guard let element = focusedElement() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                bundleIdentifier: frontmostApplicationBundleIdentifier(),
                role: nil,
                text: nil,
                isEditable: false,
                isFocusedTarget: false,
                failureReason: "no-focused-element",
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        let bundleIdentifier = frontmostApplicationBundleIdentifier()
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isEditable = isLikelyEditable(element: element)
        let isFocusedTarget = copyBooleanAttribute(kAXFocusedAttribute as String, from: element) ?? false
        let selectedRange = copySelectedTextRange(from: element)

        guard isEditable else {
            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                role: role,
                text: nil,
                isEditable: false,
                isFocusedTarget: isFocusedTarget,
                failureReason: "focused-element-not-editable",
            )
        }

        if let value = copyTextAttribute(kAXValueAttribute as String, from: element) {
            if Self.shouldTreatAXValueAsUnreadable(role: role, value: value, selectedRange: selectedRange) {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "missing-ax-value",
                )
            }
            if let placeholder = copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element), placeholder == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "value-matched-placeholder",
                )
            }
            if let title = copyTextAttribute(kAXTitleAttribute as String, from: element), title == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "value-matched-title",
                )
            }

            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                role: role,
                text: value,
                isEditable: true,
                isFocusedTarget: isFocusedTarget,
                failureReason: nil,
            )
        }

        return CurrentInputTextSnapshot(
            processID: processID,
            processName: processName,
            bundleIdentifier: bundleIdentifier,
            role: role,
            text: nil,
            isEditable: true,
            isFocusedTarget: isFocusedTarget,
            failureReason: "missing-ax-value",
        )
    }

    func currentInputText() async -> String? {
        await currentInputTextSnapshot().text
    }

    func replaceSelection(text: String) throws {
        try performAXOperationOnMainThread {
            try self.setText(text, replaceSelection: true)
        }
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
                + "focused=\(snapshot.isFocusedTarget) "
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

// swiftlint:enable file_length function_body_length identifier_name line_length trailing_comma type_body_length
