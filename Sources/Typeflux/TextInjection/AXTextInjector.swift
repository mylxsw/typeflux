// swiftlint:disable file_length function_body_length identifier_name line_length trailing_comma type_body_length
import AppKit
import ApplicationServices
import Foundation
import os

enum TextTargetCapability: Equatable {
    case writable
    case notWritable
    case opaque
}

final class LockedPasteboardStringResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func store(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class LockedPasteboardSnapshotResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AXTextInjector.PasteboardSnapshot?

    func store(_ value: AXTextInjector.PasteboardSnapshot?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> AXTextInjector.PasteboardSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class UncheckedSendableReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

final class AXTextInjector: TextInjector {
    static let nativeEditableRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXComboBox",
        "AXSearchField"
    ]

    static let genericEditableRoles: Set<String> = [
        "AXGroup",
        "AXWebArea",
        "AXUnknown"
    ]

    static let opaqueContainerRoles: Set<String> = [
        "AXColumn",
        "AXGrid",
        "AXLayoutArea",
        "AXList",
        "AXOutline",
        "AXRow",
        "AXScrollArea",
        "AXSplitGroup",
        "AXTabGroup",
        "AXTable",
        "AXWindow"
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
        "AXWindow"
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
    var lastApplicationStateFailureReason: String?
    struct PasteboardItemSnapshot {
        let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    struct PasteboardSnapshot {
        let changeCount: Int
        let items: [PasteboardItemSnapshot]
    }

    struct SelectionContext {
        let element: AXUIElement
        let windowElement: AXUIElement?
        let range: CFRange?
        let processID: pid_t?
        let processName: String?
        let selectedText: String?
        let role: String?
        let subrole: String?
        let identifier: String?
        let position: CGPoint?
        let size: CGSize?
        let windowPosition: CGPoint?
        let windowSize: CGSize?
        let windowTitle: String?
        let isFocusedTarget: Bool
        let source: String
        let capturedAt: Date

        init(
            element: AXUIElement,
            windowElement: AXUIElement? = nil,
            range: CFRange?,
            processID: pid_t?,
            processName: String?,
            selectedText: String?,
            role: String?,
            subrole: String? = nil,
            identifier: String? = nil,
            position: CGPoint? = nil,
            size: CGSize? = nil,
            windowPosition: CGPoint? = nil,
            windowSize: CGSize? = nil,
            windowTitle: String?,
            isFocusedTarget: Bool,
            source: String,
            capturedAt: Date
        ) {
            self.element = element
            self.windowElement = windowElement
            self.range = range
            self.processID = processID
            self.processName = processName
            self.selectedText = selectedText
            self.role = role
            self.subrole = subrole
            self.identifier = identifier
            self.position = position
            self.size = size
            self.windowPosition = windowPosition
            self.windowSize = windowSize
            self.windowTitle = windowTitle
            self.isFocusedTarget = isFocusedTarget
            self.source = source
            self.capturedAt = capturedAt
        }
    }

    struct ApplicationStateContext {
        let text: String
        let selectedRange: CFRange?
    }

    struct TypefluxNativeTextTarget {
        let textView: NSTextView
        let window: NSWindow?
    }

    struct ExternalSelectionCaptureTarget {
        let processID: pid_t?
        let processName: String?
        let bundleIdentifier: String?
    }

    enum SelectionCapturePreflight {
        case completed(TextSelectionSnapshot)
        case external(ExternalSelectionCaptureTarget)
    }

    nonisolated(unsafe) static var didRequestAccessibility = false
    static let copySelectionTimeoutMilliseconds = 180
    static let documentContextMaxBytes = 2_000_000
    static let applicationStateContextMaxBytes = 2_000_000
    static let visibleTextContextMaxNodes = 4000
    static let visibleTextContextSearchDepth = 16
    static let visibleTextContextMaxCharacters = 60000
    static let copyShortcutKeyCode: CGKeyCode = 8
    static let selectionContextLifetime: TimeInterval = 180
    static let maximumSelectionContextCount = 16
    static let focusedDescendantSearchDepth = 10
    static let selectionDescendantSearchMaxNodes = 96
    static let replacementAXMessagingTimeout: Float = 0.25
    static let pasteboardReadTimeoutMilliseconds = 250
    static let pasteboardSnapshotTimeoutMilliseconds = 250
    static let maximumPasteboardSnapshotBytes = 8 * 1_024 * 1_024
    /// Pasteboard history tools use this convention to exclude temporary payloads.
    static let transientPasteboardType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )

    var storedLatestSelectionContext: SelectionContext?
    let stateLock = NSLock()
    var latestSelectionContext: SelectionContext? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedLatestSelectionContext
        }
        set {
            stateLock.lock()
            storedLatestSelectionContext = newValue
            stateLock.unlock()
        }
    }
    @MainActor var deliveryInProgress = false

    @MainActor
    func acquireTextOperation() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while deliveryInProgress {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw TextDeliveryError.busy }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        deliveryInProgress = true
    }
    let selectionContextLock = NSLock()
    var selectionContexts: [UUID: SelectionContext] = [:]
    let selectionReplacementQueue = DispatchQueue(
        label: "ai.gulu.app.typeflux.selection-replacement",
        qos: .userInitiated
    )
    let pasteboardReadQueue = DispatchQueue(
        label: "ai.gulu.app.typeflux.pasteboard-read",
        qos: .userInitiated
    )
    let pasteboardSnapshotQueue = DispatchQueue(
        label: "ai.gulu.app.typeflux.pasteboard-snapshot",
        qos: .userInitiated
    )

    func isTypefluxOwnedTarget(processID: pid_t?, bundleIdentifier: String?) -> Bool {
        if processID == getpid() {
            return true
        }

        if let bundleIdentifier, bundleIdentifier == Bundle.main.bundleIdentifier {
            return true
        }

        return false
    }

    func typefluxFrontmostWindow() -> NSWindow? {
        guard isTypefluxOwnedTarget(
            processID: frontmostProcessID(),
            bundleIdentifier: frontmostApplicationBundleIdentifier()
        ) else {
            return nil
        }

        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    func typefluxNativeTextTarget() -> TypefluxNativeTextTarget? {
        guard let window = typefluxFrontmostWindow() else { return nil }
        guard !TypefluxWindowIdentity.isAskAnswerWindow(window) else { return nil }
        guard let textView = window.firstResponder as? NSTextView else { return nil }
        guard textView.isEditable || textView.isSelectable else { return nil }
        return TypefluxNativeTextTarget(textView: textView, window: window)
    }

    func typefluxReadOnlyWindowSelectionSnapshot(source: String) -> TextSelectionSnapshot {
        let window = typefluxFrontmostWindow()
        return TextSelectionSnapshot(
            processID: frontmostProcessID(),
            processName: frontmostApplicationName() ?? "Typeflux",
            bundleIdentifier: frontmostApplicationBundleIdentifier() ?? Bundle.main.bundleIdentifier,
            selectedRange: nil,
            selectedText: nil,
            source: source,
            isEditable: false,
            role: nil,
            windowTitle: window?.title,
            isFocusedTarget: false
        )
    }

    func typefluxNativeSelectionSnapshot(target: TypefluxNativeTextTarget) -> TextSelectionSnapshot {
        let selectedRange = target.textView.selectedRange()
        let selectedText: String? = if selectedRange.length > 0,
                                       selectedRange.location != NSNotFound,
                                       NSMaxRange(selectedRange) <= target.textView.string.utf16.count {
            (target.textView.string as NSString).substring(with: selectedRange)
        } else {
            nil
        }

        return TextSelectionSnapshot(
            processID: frontmostProcessID(),
            processName: frontmostApplicationName() ?? "Typeflux",
            bundleIdentifier: frontmostApplicationBundleIdentifier() ?? Bundle.main.bundleIdentifier,
            selectedRange: CFRange(location: selectedRange.location, length: selectedRange.length),
            selectedText: selectedText,
            source: "typeflux-native",
            isEditable: target.textView.isEditable,
            role: "NSTextView",
            windowTitle: target.window?.title,
            isFocusedTarget: true,
            nativeTarget: NativeTextSelectionTarget(textView: target.textView, window: target.window)
        )
    }

    func typefluxNativeInputSnapshot(target: TypefluxNativeTextTarget) -> CurrentInputTextSnapshot {
        let selectedRange = target.textView.selectedRange()
        return CurrentInputTextSnapshot(
            processID: frontmostProcessID(),
            processName: frontmostApplicationName() ?? "Typeflux",
            bundleIdentifier: frontmostApplicationBundleIdentifier() ?? Bundle.main.bundleIdentifier,
            role: "NSTextView",
            text: target.textView.string,
            selectedRange: CFRange(location: selectedRange.location, length: selectedRange.length),
            isEditable: target.textView.isEditable,
            isFocusedTarget: true,
            failureReason: nil,
            documentURL: nil,
            textSource: "typeflux-native"
        )
    }

    func typefluxOwnedSelectionSnapshot(source: String) -> TextSelectionSnapshot {
        TextSelectionSnapshot(
            processID: frontmostProcessID(),
            processName: frontmostApplicationName() ?? "Typeflux",
            bundleIdentifier: frontmostApplicationBundleIdentifier() ?? Bundle.main.bundleIdentifier,
            selectedRange: nil,
            selectedText: nil,
            source: source,
            isEditable: false,
            role: nil,
            windowTitle: nil,
            isFocusedTarget: false
        )
    }

    func typefluxOwnedInputSnapshot(failureReason: String) -> CurrentInputTextSnapshot {
        CurrentInputTextSnapshot(
            processID: frontmostProcessID(),
            processName: frontmostApplicationName() ?? "Typeflux",
            bundleIdentifier: frontmostApplicationBundleIdentifier() ?? Bundle.main.bundleIdentifier,
            role: nil,
            text: nil,
            selectedRange: nil,
            isEditable: false,
            isFocusedTarget: false,
            failureReason: failureReason
        )
    }

    static func targetCapability(
        role: String?,
        hasSelectedRange: Bool,
        hasSettableTextAttributes: Bool
    ) -> TextTargetCapability {
        if nativeEditableRoles.contains(role ?? "") {
            return .writable
        }

        if opaqueContainerRoles.contains(role ?? "") {
            return .opaque
        }

        if let role, nonEditableFalsePositiveRoles.contains(role) {
            return .notWritable
        }

        if genericEditableRoles.contains(role ?? "") {
            return hasSelectedRange || hasSettableTextAttributes ? .writable : .opaque
        }

        if hasSelectedRange && hasSettableTextAttributes {
            return .writable
        }

        return .opaque
    }

    static func replacingUTF16Range(in source: String, range: CFRange, with replacement: String) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let nsRange = NSRange(location: range.location, length: range.length)
        let source = source as NSString
        guard range.location <= source.length, range.length <= source.length - range.location else { return nil }
        return source.replacingCharacters(in: nsRange, with: replacement)
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
           selectedRange.length >= 0 {
            score += 4
        }

        if candidate.isFocused == true {
            score += 2
        }

        return score
    }

    func performAXReadOnMainActor<T: Sendable>(
        _ body: @escaping @MainActor () -> T
    ) async -> T {
        await MainActor.run {
            body()
        }
    }

    @MainActor
    func selectionSnapshot(for intent: SelectionCaptureIntent) async -> TextSelectionSnapshot {
        do { try await acquireTextOperation() }
        catch { return TextSelectionSnapshot(source: "capture-cancelled-or-busy") }
        defer { deliveryInProgress = false }
        let preflight = selectionCapturePreflight()
        switch preflight {
        case let .completed(snapshot):
            return snapshot
        case let .external(target):
            let cancellation = SelectionReplacementCancellationToken()
            do {
                return try await performSelectionReplacementWork(cancellationToken: cancellation) {
                    try self.readExternalSelectionSnapshot(target: target, intent: intent, cancellation: cancellation)
                }
            } catch {
                return TextSelectionSnapshot(source: "capture-cancelled-or-busy")
            }
        }
    }

    @MainActor
    func selectionCapturePreflight() -> SelectionCapturePreflight {
        if let target = typefluxNativeTextTarget() {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] captured Typeflux native text selection"
            )
            latestSelectionContext = nil
            return .completed(typefluxNativeSelectionSnapshot(target: target))
        }

        if TypefluxWindowIdentity.isAskAnswerWindow(typefluxFrontmostWindow()) {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] skipped selection snapshot for Typeflux Ask Answer window"
            )
            latestSelectionContext = nil
            return .completed(typefluxReadOnlyWindowSelectionSnapshot(source: "typeflux-ask-answer-window"))
        }

        guard AXIsProcessTrusted() else {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url =
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return .completed(TextSelectionSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                bundleIdentifier: frontmostApplicationBundleIdentifier(),
                selectedRange: nil,
                selectedText: nil,
                source: "unavailable",
                isEditable: false,
                role: nil,
                windowTitle: nil,
                isFocusedTarget: false
            ))
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        let bundleIdentifier = frontmostApplicationBundleIdentifier()
        if isTypefluxOwnedTarget(processID: processID, bundleIdentifier: bundleIdentifier) {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] skipped selection snapshot for Typeflux non-text frontmost target"
            )
            latestSelectionContext = nil
            return .completed(typefluxReadOnlyWindowSelectionSnapshot(source: "typeflux-non-text-window"))
        }

        return .external(ExternalSelectionCaptureTarget(
            processID: processID,
            processName: processName,
            bundleIdentifier: bundleIdentifier
        ))
    }

    func readExternalSelectionSnapshot(
        target: ExternalSelectionCaptureTarget,
        intent: SelectionCaptureIntent,
        cancellation: SelectionReplacementCancellationToken
    ) throws -> TextSelectionSnapshot {
        try cancellation.checkCancellation()
        let processID = target.processID
        let processName = target.processName
        let bundleIdentifier = target.bundleIdentifier
        guard processID != nil, processID == frontmostProcessID() else {
            logger.debug("selection target changed before capture started")
            latestSelectionContext = nil
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                source: "target-changed",
                isEditable: false,
                isFocusedTarget: false,
                replacementSafety: SelectionReplacementSafety.none
            )
        }
        logger
            .debug(
                "getSelectionSnapshot — app: \(processName ?? "?", privacy: .public) (pid: \(processID.map(String.init) ?? "?", privacy: .public))"
            )

        if let result = readSelectedText(processID: processID, processName: processName) {
            try cancellation.checkCancellation()
            // Compute editability from the SAME element that produced the text,
            // avoiding a race where a second focusedElement() call returns a different element.
            let editability = isLikelyEditable(element: result.context.element)
            latestSelectionContext = result.context
            let replacementContextID = registerSelectionContext(result.context)
            logger
                .debug(
                    "source=ax-api  role=\(result.context.role ?? "nil", privacy: .public)  range=\(result.context.range.map { "[\($0.location),\($0.length)]" } ?? "nil", privacy: .public)  isEditable=\(editability ? "true" : "false", privacy: .public)  isFocusedTarget=\(result.context.isFocusedTarget ? "true" : "false", privacy: .public)  textLength=\(result.text.utf16.count)"
                )
            return TextSelectionSnapshot(
                processID: result.context.processID,
                processName: result.context.processName,
                bundleIdentifier: bundleIdentifier,
                selectedRange: result.context.range,
                selectedText: result.text,
                source: result.context.source,
                isEditable: editability,
                role: result.context.role,
                windowTitle: result.context.windowTitle,
                isFocusedTarget: result.context.isFocusedTarget,
                replacementContextID: replacementContextID,
                replacementSafety: Self.replacementSafety(
                    source: result.context.source,
                    selectedRange: result.context.range,
                    isEditable: editability,
                    isFocusedTarget: result.context.isFocusedTarget,
                    selectedText: result.text,
                    intent: intent,
                    capability: targetCapability(element: result.context.element)
                )
            )
        }

        let clipboardProbeElement = processID.flatMap(deliveryFocusedElement(for:))
        let clipboardProbeRange = clipboardProbeElement.flatMap(copySelectedTextRange(from:))
        let clipboardProbeIsEditable = clipboardProbeElement.map(isLikelyEditable(element:)) ?? false
        let clipboardProbeCapability = clipboardProbeElement.map(targetCapability(element:))
        let shouldProbeClipboardSelection = Self.shouldProbeClipboardSelection(
            selectedRange: clipboardProbeRange,
            intent: intent
        )
        if shouldProbeClipboardSelection {
            logger.debug("ax-api returned nil — trying clipboard-copy")
        } else {
            logger.debug("ax-api returned nil — no reliable selection target, skipping clipboard-copy")
        }

        try cancellation.checkCancellation()
        if shouldProbeClipboardSelection,
           let copiedText = readSelectedTextViaCopy(
            processID: processID,
            milliseconds: Self.copySelectionTimeoutMilliseconds
        ) {
            let focusedElement = clipboardProbeElement
            let focusedWindow = processID.flatMap(focusedWindowElement(for:))
            let selectionWindow = focusedElement.flatMap(containingWindow(of:))
            let editability = clipboardProbeIsEditable
            // Clipboard copy succeeded → text IS selected in the frontmost app's process.
            // When selectionWindow is nil (e.g. Electron/Chromium AX hierarchy doesn't expose
            // a traversable parent chain to the window), we still trust isFocusedTarget = true
            // because the Cmd+C was sent to processID (the frontmost app) and succeeded.
            let windowMatches = focusedWindow.map { w in
                selectionWindow.map { s in windowsMatch(w, s) } ?? true
            } ?? (focusedElement != nil)
            let isFocusedTarget = frontmostProcessID() == processID && windowMatches
            let context = SelectionContext(
                element: focusedElement ?? AXUIElementCreateSystemWide(),
                windowElement: focusedWindow ?? selectionWindow,
                range: nil,
                processID: processID,
                processName: processName,
                selectedText: copiedText,
                role: focusedElement.flatMap {
                    copyStringAttribute(kAXRoleAttribute as String, from: $0)
                },
                subrole: focusedElement.flatMap {
                    copyStringAttribute(kAXSubroleAttribute as String, from: $0)
                },
                identifier: focusedElement.flatMap {
                    copyStringAttribute(kAXIdentifierAttribute as String, from: $0)
                },
                position: focusedElement.flatMap {
                    copyCGPointAttribute(kAXPositionAttribute as String, from: $0)
                },
                size: focusedElement.flatMap {
                    copyCGSizeAttribute(kAXSizeAttribute as String, from: $0)
                },
                windowPosition: (focusedWindow ?? selectionWindow).flatMap {
                    copyCGPointAttribute(kAXPositionAttribute as String, from: $0)
                },
                windowSize: (focusedWindow ?? selectionWindow).flatMap {
                    copyCGSizeAttribute(kAXSizeAttribute as String, from: $0)
                },
                windowTitle: selectionWindow.flatMap(windowTitle(of:)) ?? focusedWindowTitle(for: processID),
                isFocusedTarget: isFocusedTarget,
                source: "clipboard-copy",
                capturedAt: Date()
            )
            latestSelectionContext = context
            let replacementContextID = registerSelectionContext(context)
            logger
                .debug(
                    "source=clipboard-copy  focusedWindow=\(focusedWindow != nil ? "present" : "nil", privacy: .public)  selectionWindow=\(selectionWindow != nil ? "present" : "nil", privacy: .public)  isFocusedTarget=\(isFocusedTarget ? "true" : "false", privacy: .public)  textLength=\(copiedText.utf16.count)"
                )
            let safety = Self.replacementSafety(
                source: "clipboard-copy", selectedRange: clipboardProbeRange,
                isEditable: editability, isFocusedTarget: context.isFocusedTarget,
                selectedText: copiedText, intent: intent, capability: clipboardProbeCapability
            )
            NetworkDebugLogger.logMessage(
                "[Text Selection] copy authorization capability=\(String(describing: clipboardProbeCapability)) safety=\(safety) focused=\(context.isFocusedTarget)"
            )
            // Preserve the distinction between observed AX editability and authority
            // to attempt an explicitly requested, revalidated paste replacement.
            return TextSelectionSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                selectedRange: nil,
                selectedText: copiedText,
                source: "clipboard-copy",
                isEditable: editability,
                role: context.role,
                windowTitle: context.windowTitle,
                isFocusedTarget: context.isFocusedTarget,
                replacementContextID: replacementContextID,
                replacementSafety: safety
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
            isFocusedTarget: false
        )
    }

    /// A copy response alone is not proof of a selection: some applications copy the
    /// entire field when no range is selected. Ordinary dictation therefore requires
    /// positive range evidence. An explicit selection command may probe an opaque target,
    /// including web bridges that report a stale collapsed range. Explicit copy-backed
    /// replacement requires target and source-text revalidation before dispatch.
    static func shouldProbeClipboardSelection(
        selectedRange: CFRange?,
        intent: SelectionCaptureIntent
    ) -> Bool {
        switch intent {
        case .automaticInsertion:
            selectedRange?.length ?? 0 > 0
        case .explicitSelectionAction:
            true
        }
    }

    static func replacementSafety(
        source: String,
        selectedRange: CFRange?,
        isEditable: Bool,
        isFocusedTarget: Bool,
        selectedText: String? = nil,
        intent: SelectionCaptureIntent = .automaticInsertion,
        capability: TextTargetCapability? = nil
    ) -> SelectionReplacementSafety {
        guard isFocusedTarget, capability != .notWritable else { return .resultOnly }
        // Explicit selection intent plus captured AX/copied text can authorize an
        // opaque editor without an AX range. The one-shot context must revalidate
        // the exact source text through the capture mechanism in the same target
        // immediately before dispatch.
        if intent == .explicitSelectionAction, selectedText?.isEmpty == false,
           (source == "clipboard-copy" || (source == "accessibility" && !isEditable)),
           capability == .writable || capability == .opaque {
            return .verifiedPaste
        }
        guard isEditable else { return .resultOnly }
        if selectedRange?.length ?? 0 <= 0 {
            // Valid AX selected text is positive evidence even when a web bridge
            // omits its range. Incidental copy capture alone grants no authority.
            return source == "accessibility" && selectedText?.isEmpty == false ? .verifiedPaste : .resultOnly
        }
        return source == "clipboard-copy" ? .verifiedPaste : .directAccessibility
    }

    func currentInputTextSnapshot() async -> CurrentInputTextSnapshot {
        await performAXReadOnMainActor {
            self.readCurrentInputTextSnapshot()
        }
    }

    func readCurrentInputTextSnapshot() -> CurrentInputTextSnapshot {
        if let target = typefluxNativeTextTarget() {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] captured Typeflux native input snapshot"
            )
            return typefluxNativeInputSnapshot(target: target)
        }

        if TypefluxWindowIdentity.isAskAnswerWindow(typefluxFrontmostWindow()) {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] skipped input snapshot for Typeflux Ask Answer window"
            )
            return typefluxOwnedInputSnapshot(failureReason: "typeflux-ask-answer-window")
        }

        guard AXIsProcessTrusted() else {
            return CurrentInputTextSnapshot(
                processID: frontmostProcessID(),
                processName: frontmostApplicationName(),
                bundleIdentifier: frontmostApplicationBundleIdentifier(),
                role: nil,
                text: nil,
                selectedRange: nil,
                isEditable: false,
                isFocusedTarget: false,
                failureReason: "accessibility-not-trusted"
            )
        }

        let processID = frontmostProcessID()
        let processName = frontmostApplicationName()
        let bundleIdentifier = frontmostApplicationBundleIdentifier()
        if isTypefluxOwnedTarget(processID: processID, bundleIdentifier: bundleIdentifier) {
            NetworkDebugLogger.logMessage(
                "[AXTextInjector] skipped input snapshot for Typeflux non-text frontmost target"
            )
            return typefluxOwnedInputSnapshot(failureReason: "typeflux-non-text-window")
        }

        guard let element = focusedElement() else {
            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                role: nil,
                text: nil,
                selectedRange: nil,
                isEditable: false,
                isFocusedTarget: false,
                failureReason: "no-focused-element"
            )
        }

        let role = copyStringAttribute(kAXRoleAttribute as String, from: element)
        let isEditable = isLikelyEditable(element: element)
        let isFocusedTarget = copyBooleanAttribute(kAXFocusedAttribute as String, from: element) ?? false
        let selectedRange = copySelectedTextRange(from: element)
        let documentURL = documentURL(for: element, processID: processID)
        let shouldPreferApplicationState = Self.shouldPreferApplicationStateContextBeforeAXValue(
            bundleIdentifier: bundleIdentifier,
            role: role,
            isFocusedTarget: isFocusedTarget
        )
        let shouldSuppressAXValue = Self.shouldSuppressAXValueContext(
            bundleIdentifier: bundleIdentifier,
            role: role,
            isFocusedTarget: isFocusedTarget
        )

        guard isEditable else {
            let documentText = documentURL.flatMap(readDocumentContextText(from:))
            let applicationStateContext = documentText == nil ? applicationStateContext(
                bundleIdentifier: bundleIdentifier,
                selectedText: latestSelectionContext?.selectedText,
                windowTitle: latestSelectionContext?.windowTitle ?? processID.flatMap(focusedWindowTitle(for:))
            ) : nil
            let visibleText = documentText == nil && applicationStateContext == nil ? visibleTextContext(
                for: element,
                processID: processID
            ) : nil
            let contextText = documentText ?? applicationStateContext?.text ?? visibleText
            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                role: role,
                text: contextText,
                selectedRange: applicationStateContext?.selectedRange ?? selectedRange,
                isEditable: false,
                isFocusedTarget: isFocusedTarget,
                failureReason: inputContextFailureReason(
                    defaultReason: "focused-element-not-editable",
                    contextReason: "focused-element-not-editable-context",
                    contextText: contextText
                ),
                documentURL: documentURL,
                textSource: Self.contextTextSource(
                    documentText: documentText,
                    applicationStateText: applicationStateContext?.text,
                    visibleText: visibleText
                )
            )
        }

        if shouldPreferApplicationState {
            let applicationStateContext = applicationStateContext(
                bundleIdentifier: bundleIdentifier,
                selectedText: latestSelectionContext?.selectedText,
                windowTitle: latestSelectionContext?.windowTitle ?? processID.flatMap(focusedWindowTitle(for:))
            )
            if let applicationStateContext {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: applicationStateContext.text,
                    selectedRange: applicationStateContext.selectedRange,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "ax-value-bypassed-application-state-context",
                    documentURL: documentURL,
                    textSource: "application-state"
                )
            }
        }

        if let value = copyTextAttribute(kAXValueAttribute as String, from: element) {
            if Self.shouldTreatAXValueAsUnreadable(role: role, value: value, selectedRange: selectedRange) {
                let documentText = documentURL.flatMap(readDocumentContextText(from:))
                let applicationStateContext = documentText == nil ? applicationStateContext(
                    bundleIdentifier: bundleIdentifier,
                    selectedText: latestSelectionContext?.selectedText,
                    windowTitle: latestSelectionContext?.windowTitle ?? processID.flatMap(focusedWindowTitle(for:))
                ) : nil
                let visibleText = documentText == nil && applicationStateContext == nil ? visibleTextContext(
                    for: element,
                    processID: processID
                ) : nil
                let contextText = documentText ?? applicationStateContext?.text ?? visibleText
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: contextText,
                    selectedRange: applicationStateContext?.selectedRange ?? selectedRange,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: inputContextFailureReason(
                        defaultReason: "missing-ax-value",
                        contextReason: "missing-ax-value-context",
                        contextText: contextText
                    ),
                    documentURL: documentURL,
                    textSource: Self.contextTextSource(
                        documentText: documentText,
                        applicationStateText: applicationStateContext?.text,
                        visibleText: visibleText
                    )
                )
            }
            if let placeholder = copyTextAttribute(kAXPlaceholderValueAttribute as String, from: element),
               placeholder == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    selectedRange: selectedRange,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "value-matched-placeholder",
                    documentURL: documentURL
                )
            }
            if let title = copyTextAttribute(kAXTitleAttribute as String, from: element), title == value {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    selectedRange: selectedRange,
                    isEditable: true,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: "value-matched-title",
                    documentURL: documentURL
                )
            }

            if shouldSuppressAXValue {
                return CurrentInputTextSnapshot(
                    processID: processID,
                    processName: processName,
                    bundleIdentifier: bundleIdentifier,
                    role: role,
                    text: nil,
                    selectedRange: nil,
                    isEditable: false,
                    isFocusedTarget: isFocusedTarget,
                    failureReason: inputContextFailureReason(
                        defaultReason: "browser-chrome-ui-ax-value-ignored",
                        contextReason: "browser-chrome-ui-ax-value-ignored-context",
                        contextText: nil
                    ),
                    documentURL: documentURL
                )
            }

            return CurrentInputTextSnapshot(
                processID: processID,
                processName: processName,
                bundleIdentifier: bundleIdentifier,
                role: role,
                text: value,
                selectedRange: selectedRange,
                isEditable: true,
                isFocusedTarget: isFocusedTarget,
                failureReason: nil,
                documentURL: documentURL,
                textSource: "ax-value"
            )
        }

        let documentText = documentURL.flatMap(readDocumentContextText(from:))
        let applicationStateContext = documentText == nil ? applicationStateContext(
            bundleIdentifier: bundleIdentifier,
            selectedText: latestSelectionContext?.selectedText,
            windowTitle: latestSelectionContext?.windowTitle ?? processID.flatMap(focusedWindowTitle(for:))
        ) : nil
        let visibleText = documentText == nil && applicationStateContext == nil ? visibleTextContext(
            for: element,
            processID: processID
        ) : nil
        let contextText = documentText ?? applicationStateContext?.text ?? visibleText
        return CurrentInputTextSnapshot(
            processID: processID,
            processName: processName,
            bundleIdentifier: bundleIdentifier,
            role: role,
            text: contextText,
            selectedRange: applicationStateContext?.selectedRange ?? selectedRange,
            isEditable: true,
            isFocusedTarget: isFocusedTarget,
            failureReason: inputContextFailureReason(
                defaultReason: "missing-ax-value",
                contextReason: "missing-ax-value-context",
                contextText: contextText
            ),
            documentURL: documentURL,
            textSource: Self.contextTextSource(
                documentText: documentText,
                applicationStateText: applicationStateContext?.text,
                visibleText: visibleText
            )
        )
    }

    func currentInputText() async -> String? {
        await currentInputTextSnapshot().text
    }

    func inputContextFailureReason(defaultReason: String, contextReason: String, contextText: String?) -> String {
        if contextText != nil {
            return contextReason
        }

        guard let stateFailure = lastApplicationStateFailureReason else {
            return defaultReason
        }
        return "\(defaultReason)-\(stateFailure)"
    }

    func selectionContextSummary(_ context: SelectionContext?) -> String {
        guard let context else { return "<nil>" }
        let range = context.range.map { "[\($0.location),\($0.length)]" } ?? "nil"
        return
            "pid=\(context.processID.map(String.init) ?? "nil") process=\(context.processName ?? "nil") "
                + "role=\(context.role ?? "nil") window=\(context.windowTitle ?? "nil") "
                + "source=\(context.source) focused=\(context.isFocusedTarget) range=\(range) "
                + "selectedTextLength=\(context.selectedText?.count ?? 0)"
    }

    func snapshotSummary(_ snapshot: CurrentInputTextSnapshot) -> String {
        "role=\(snapshot.role ?? "nil") editable=\(snapshot.isEditable) "
            + "focused=\(snapshot.isFocusedTarget) failure=\(snapshot.failureReason ?? "nil") "
            + "textLength=\(snapshot.text?.utf16.count ?? 0) textSource=\(snapshot.textSource ?? "nil")"
    }

    func elementSummary(_ element: AXUIElement) -> String {
        let role = copyStringAttribute(kAXRoleAttribute as String, from: element) ?? "nil"
        let focused = copyBooleanAttribute(kAXFocusedAttribute as String, from: element).map(String.init) ?? "nil"
        let range = copySelectedTextRange(from: element).map { "[\($0.location),\($0.length)]" } ?? "nil"
        return "role=\(role) focused=\(focused) selectedRange=\(range)"
    }

}

// swiftlint:enable file_length function_body_length identifier_name line_length trailing_comma type_body_length
