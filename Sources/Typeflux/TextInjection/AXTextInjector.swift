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

final class PasteboardDeliveryProbe: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var dispatchedAt: TimeInterval?
    private var requestTimes: [TimeInterval] = []

    init(
        text: String,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.text = text
        self.now = now
    }

    func markDispatched() {
        lock.lock()
        dispatchedAt = now()
        lock.unlock()
    }

    var wasRequestedAfterDispatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let dispatchedAt else { return false }
        return requestTimes.contains { $0 >= dispatchedAt }
    }

    var wasRequestedBeforeDispatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let dispatchedAt else { return !requestTimes.isEmpty }
        return requestTimes.contains { $0 < dispatchedAt }
    }

    func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requestTimes.append(now())
        lock.unlock()
        item.setString(text, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_: NSPasteboard) {}
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
    let settingsStore: SettingsStore?
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
    static let legacyPasteRestoreDelayNanoseconds: UInt64 = 150_000_000
    static let verifiedPasteRestoreDelayNanoseconds: UInt64 = 150_000_000
    /// Slow clipboard consumers (iTerm2 / Terminal.app / Warp bracketed paste,
    /// "warn before pasting" dialogs, paste-slowly modes) may not read the
    /// pasteboard until well after Cmd+V is dispatched. When we have no way to
    /// verify the paste landed (plain insert into non-AX-readable targets),
    /// keep our transcription on the pasteboard long enough that the consumer
    /// reads it before we restore the user's previous clipboard content.
    static let unverifiedPasteRestoreDelayNanoseconds: UInt64 = 1_500_000_000
    static let pasteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    static let pasteVerificationAttempts = 4
    static let axWriteVerificationPollIntervalMicroseconds: useconds_t = 120_000
    static let axWriteVerificationAttempts = 4
    static let focusRestoreDelayMicroseconds: useconds_t = 250_000
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
    static let replacementAXMessagingTimeout: Float = 0.25
    static let pasteboardReadTimeoutMilliseconds = 250
    static let pasteboardSnapshotTimeoutMilliseconds = 250
    static let maximumPasteboardSnapshotBytes = 8 * 1_024 * 1_024

    var storedLatestSelectionContext: SelectionContext?
    var storedLastInjectionMethod: TextInjectionMethod?
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
    var lastInjectionMethod: TextInjectionMethod? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return storedLastInjectionMethod
        }
        set {
            stateLock.lock()
            storedLastInjectionMethod = newValue
            stateLock.unlock()
        }
    }
    var activePasteboardDeliveryProbe: PasteboardDeliveryProbe?
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
            isFocusedTarget: true
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

    func insertIntoTypefluxNativeTextTarget(_ text: String, replaceSelection: Bool) throws -> Bool {
        guard let target = typefluxNativeTextTarget() else { return false }
        guard target.textView.isEditable else {
            throw NSError(
                domain: "AXTextInjector",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Focused Typeflux text target is not editable"]
            )
        }

        let selectedRange = target.textView.selectedRange()
        let replacementRange = replaceSelection
            ? selectedRange
            : NSRange(location: selectedRange.location, length: selectedRange.length)
        target.textView.insertText(text, replacementRange: replacementRange)
        NetworkDebugLogger.logMessage(
            "[Text Injection] completed via Typeflux native text target"
        )
        return true
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

    enum PasteVerificationResult: Equatable {
        case success
        case failure(String)
        case indeterminate
    }

    static func finalPasteVerification(
        lastReadback: PasteVerificationResult,
        payloadRequestedAfterDispatch: Bool,
        payloadRequestedBeforeDispatch: Bool,
        targetStableThroughout: Bool
    ) -> PasteVerificationResult {
        guard targetStableThroughout else {
            return .failure("focused-target-changed")
        }

        switch lastReadback {
        case .success:
            return .success
        case .failure:
            return lastReadback
        case .indeterminate:
            break
        }

        if payloadRequestedAfterDispatch {
            return .success
        }

        return .failure(
            payloadRequestedBeforeDispatch
                ? "pasteboard-request-contaminated-before-dispatch"
                : "pasteboard-payload-not-requested"
        )
    }

    static func successfulAXWriteIsCommitted(verification: PasteVerificationResult) -> Bool {
        switch verification {
        case .success, .indeterminate:
            return true
        case let .failure(reason):
            // AX reported that the write itself succeeded synchronously. A later focus change
            // only makes read-back unavailable; retrying with Cmd+V could duplicate the text in
            // a new target. Only a stable, readable target that stayed unchanged contradicts
            // the AX acknowledgement strongly enough to justify a paste fallback.
            return reason != "input-text-unchanged"
        }
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
        guard NSMaxRange(nsRange) <= source.length else { return nil }
        return source.replacingCharacters(in: nsRange, with: replacement)
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
        frontmostProcessID: pid_t?
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
        frontmostProcessID: pid_t?
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
        targetProcessID: pid_t?
    ) -> PasteDispatchMethod {
        if flagEnabled {
            return .hidTap
        }
        return targetProcessID != nil ? .postToPid : .hidTap
    }

    /// Strict paste verification is scoped to edit-apply (replace selection)
    /// flows, where a silently failed replacement must be surfaced so the user
    /// can copy the result manually.
    static func shouldPerformStrictPasteVerification(
        replaceSelection: Bool,
        strictFallbackEnabled: Bool
    ) -> Bool {
        strictFallbackEnabled && replaceSelection
    }

    /// Plain dictation uses the eager paste fast path and must never enter the
    /// synchronous verification loop. Strict verification remains scoped to
    /// selection replacement, where the original text is available for recovery.
    static func shouldAttemptPasteVerification(
        replaceSelection: Bool,
        strictFallbackEnabled: Bool
    ) -> Bool {
        shouldPerformStrictPasteVerification(
            replaceSelection: replaceSelection,
            strictFallbackEnabled: strictFallbackEnabled
        )
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

    /// Only restore the user's previous pasteboard if no other writer has
    /// touched `NSPasteboard.general` since we wrote the transcription. If the
    /// change count has advanced, either the user copied something new or a
    /// clipboard manager updated the contents — in both cases overwriting with
    /// our stale snapshot would destroy their data.
    static func shouldRestoreCapturedPasteboard(
        capturedChangeCount: Int,
        currentChangeCount: Int
    ) -> Bool {
        capturedChangeCount == currentChangeCount
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

    init(settingsStore: SettingsStore? = nil) {
        self.settingsStore = settingsStore
    }

    func performAXReadOnMainActor<T: Sendable>(
        _ body: @escaping @MainActor () -> T
    ) async -> T {
        await MainActor.run {
            body()
        }
    }

    func performAXOperationOnMainThread<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        if Thread.isMainThread {
            return try body()
        }

        return try DispatchQueue.main.sync {
            try body()
        }
    }

    func getSelectionSnapshot() async -> TextSelectionSnapshot {
        let preflight = await MainActor.run {
            self.selectionCapturePreflight()
        }
        switch preflight {
        case let .completed(snapshot):
            return snapshot
        case let .external(target):
            let injector = UncheckedSendableReference(self)
            return await withCheckedContinuation { continuation in
                selectionReplacementQueue.async {
                    continuation.resume(
                        returning: injector.value.readExternalSelectionSnapshot(target: target)
                    )
                }
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

    func readExternalSelectionSnapshot(target: ExternalSelectionCaptureTarget) -> TextSelectionSnapshot {
        let processID = target.processID
        let processName = target.processName
        let bundleIdentifier = target.bundleIdentifier
        logger
            .debug(
                "getSelectionSnapshot — app: \(processName ?? "?", privacy: .public) (pid: \(processID.map(String.init) ?? "?", privacy: .public))"
            )

        if let result = readSelectedText(processID: processID, processName: processName) {
            // Compute editability from the SAME element that produced the text,
            // avoiding a race where a second focusedElement() call returns a different element.
            let editability = isLikelyEditable(element: result.context.element)
            latestSelectionContext = result.context
            let replacementContextID = registerSelectionContext(result.context)
            logger
                .debug(
                    "source=ax-api  role=\(result.context.role ?? "nil", privacy: .public)  range=\(result.context.range.map { "[\($0.location),\($0.length)]" } ?? "nil", privacy: .public)  isEditable=\(editability ? "true" : "false", privacy: .public)  isFocusedTarget=\(result.context.isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(result.text.prefix(32)), privacy: .public)"
                )
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
                replacementContextID: replacementContextID
            )
        }

        let clipboardProbeElement = processID.flatMap(focusedElement(for:))
        let clipboardProbeRange = clipboardProbeElement.flatMap(copySelectedTextRange(from:))
        let shouldSkipClipboardProbe = Self.shouldSkipClipboardSelectionProbe(
            selectedRange: clipboardProbeRange
        )
        if shouldSkipClipboardProbe {
            logger.debug("ax-api returned nil — empty selection range, skipping clipboard-copy")
        } else {
            logger.debug("ax-api returned nil — trying clipboard-copy")
        }

        if !shouldSkipClipboardProbe,
           let copiedText = readSelectedTextViaCopy(
            processID: processID,
            milliseconds: Self.copySelectionTimeoutMilliseconds
        ) {
            let focusedElement = clipboardProbeElement
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
                    "source=clipboard-copy  focusedWindow=\(focusedWindow != nil ? "present" : "nil", privacy: .public)  selectionWindow=\(selectionWindow != nil ? "present" : "nil", privacy: .public)  isFocusedTarget=\(isFocusedTarget ? "true" : "false", privacy: .public)  text(32)=\(String(copiedText.prefix(32)), privacy: .public)"
                )
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
                role: context.role,
                windowTitle: context.windowTitle,
                isFocusedTarget: context.isFocusedTarget,
                replacementContextID: replacementContextID
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

    static func shouldSkipClipboardSelectionProbe(selectedRange: CFRange?) -> Bool {
        selectedRange?.length == 0
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

    func replaceSelection(text: String) throws {
        try performAXOperationOnMainThread {
            guard try self.insertIntoTypefluxNativeTextTarget(text, replaceSelection: true) else {
                throw self.selectionReplacementError(
                    code: 32,
                    description: "External selection replacement requires a captured target"
                )
            }
            self.lastInjectionMethod = .ax
        }
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
        let preview = snapshot.text.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        } ?? "nil"
        return
            "pid=\(snapshot.processID.map(String.init) ?? "nil") process=\(snapshot.processName ?? "nil") "
                + "role=\(snapshot.role ?? "nil") editable=\(snapshot.isEditable) "
                + "focused=\(snapshot.isFocusedTarget) "
                + "failure=\(snapshot.failureReason ?? "nil") textLength=\(snapshot.text?.count ?? 0) "
                + "document=\(snapshot.documentURL?.path ?? "nil") "
                + "textSource=\(snapshot.textSource ?? "nil") "
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
        let placeholderPreview = placeholder
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) } ?? "nil"

        return
            "role=\(role) subrole=\(subrole) focused=\(focused) editable=\(editable) "
                + "selectedRange=\(selectedRange) title=\(title) description=\(description) "
                + "valuePreview=\(valuePreview) placeholderPreview=\(placeholderPreview)"
    }
}

// swiftlint:enable file_length function_body_length identifier_name line_length trailing_comma type_body_length
