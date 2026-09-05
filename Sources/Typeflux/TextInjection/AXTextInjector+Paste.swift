import AppKit
import ApplicationServices
import Foundation

// swiftlint:disable closure_parameter_position file_length function_body_length
// swiftlint:disable identifier_name line_length
extension AXTextInjector {
    func setText(_ text: String, replaceSelection: Bool) throws {
        lastInjectionMethod = nil
        if try insertIntoTypefluxNativeTextTarget(text, replaceSelection: replaceSelection) {
            lastInjectionMethod = .ax
            return
        }

        guard !replaceSelection else {
            throw selectionReplacementError(
                code: 32,
                description: "External selection replacement requires a captured target"
            )
        }

        if TypefluxWindowIdentity.isAskAnswerWindow(typefluxFrontmostWindow()) {
            NetworkDebugLogger.logMessage(
                "[Text Injection] blocked Typeflux Ask Answer window before AX write"
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to inject text into Typeflux result windows"]
            )
        }

        if !AXIsProcessTrusted() {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            throw NSError(
                domain: "AXTextInjector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Accessibility permission required"]
            )
        }

        let processID = frontmostProcessID()
        let bundleIdentifier = frontmostApplicationBundleIdentifier()
        if isTypefluxOwnedTarget(processID: processID, bundleIdentifier: bundleIdentifier) {
            NetworkDebugLogger.logMessage(
                "[Text Injection] blocked Typeflux non-text frontmost target before AX write"
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "No editable Typeflux text target is focused"]
            )
        }

        let currentFocusedElement = focusedElement()
        let currentTargetCapability = currentFocusedElement
            .map(targetCapability(element:)) ?? .opaque

        if !replaceSelection {
            guard currentFocusedElement != nil else {
                throw NSError(
                    domain: "AXTextInjector",
                    code: 12,
                    userInfo: [NSLocalizedDescriptionKey: "No focused target is available"]
                )
            }
            if currentTargetCapability == .notWritable {
                throw NSError(
                    domain: "AXTextInjector",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Focused target is not writable"]
                )
            }

            NetworkDebugLogger.logMessage(
                "[Text Injection] plain insert using eager paste path | capability: \(String(describing: currentTargetCapability))"
            )
            try setTextViaPaste(text, replaceSelection: false)
            lastInjectionMethod = .paste
            return
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
            currentTargetCapability: \(String(describing: currentTargetCapability))
            """
        )

        if replaceSelection, let context = activeSelectionContext() {
            NetworkDebugLogger.logMessage(
                "[Text Injection] restoring selection context before replace | \(selectionContextSummary(context))"
            )
            restoreSelectionContext(context)
            contextRestored = true
            if context.range != nil,
               try insertTextViaAX(
                   text,
                   into: context.element,
                   replaceSelection: true,
                   selectionRange: context.range,
                   beforeSnapshot: beforeSnapshot
               ) {
                NetworkDebugLogger.logMessage(
                    "[Text Injection] replace completed via AX selected-text write"
                )
                latestSelectionContext = nil
                lastInjectionMethod = .ax
                return
            }
            NetworkDebugLogger.logMessage(
                "[Text Injection] AX selected-text write unavailable or unverified, falling back"
            )
        }

        if replaceSelection, let element = currentFocusedElement,
           try insertTextViaAX(
               text,
               into: element,
               replaceSelection: replaceSelection,
               selectionRange: nil,
               beforeSnapshot: beforeSnapshot
           ) {
            NetworkDebugLogger.logMessage("[Text Injection] completed via focused AX path")
            if replaceSelection {
                latestSelectionContext = nil
            }
            lastInjectionMethod = .ax
            return
        }

        NetworkDebugLogger.logMessage("[Text Injection] falling back to paste path")
        try setTextViaPaste(
            text,
            replaceSelection: replaceSelection,
            contextAlreadyRestored: contextRestored
        )
        lastInjectionMethod = .paste
        if replaceSelection {
            latestSelectionContext = nil
        }
        NetworkDebugLogger.logMessage("[Text Injection] paste path completed")
    }

    func insertTextViaAX(
        _ text: String,
        into element: AXUIElement,
        replaceSelection: Bool,
        selectionRange: CFRange?,
        beforeSnapshot: CurrentInputTextSnapshot
    ) throws -> Bool {
        guard isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element) else {
            return false
        }
        if let selectionRange {
            _ = setSelectedTextRange(selectionRange, on: element)
        }
        let replaceSelectedText = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if replaceSelectedText == .success {
            let targetProcessID = processID(of: element) ?? beforeSnapshot.processID
            let verification = verifyAXWriteApplied(
                insertedText: text,
                replaceSelection: replaceSelection,
                targetProcessID: targetProcessID,
                beforeSnapshot: beforeSnapshot
            )
            if Self.successfulAXWriteIsCommitted(verification: verification) {
                if verification == .indeterminate {
                    NetworkDebugLogger.logMessage(
                        "[Text Injection] AX write accepted; read-back unavailable, treating AX acknowledgement as committed"
                    )
                } else if case let .failure(reason) = verification {
                    NetworkDebugLogger.logMessage(
                        "[Text Injection] AX write accepted before read-back lost target: \(reason)"
                    )
                }
                return true
            }
            let afterSnapshot = readCurrentInputTextSnapshot()
            logger.debug(
                "AX selected text write reported success but verification failed; falling back"
            )
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] AX write verification failed
                replaceSelection: \(replaceSelection)
                beforeSnapshot: \(snapshotSummary(beforeSnapshot))
                afterSnapshot: \(snapshotSummary(afterSnapshot))
                """
            )
        }

        return false
    }

    func verifyAXWriteApplied(
        insertedText: String,
        replaceSelection: Bool,
        targetProcessID: pid_t?,
        beforeSnapshot: CurrentInputTextSnapshot
    ) -> PasteVerificationResult {
        var lastReadback: PasteVerificationResult = .indeterminate
        for attempt in 0 ..< Self.axWriteVerificationAttempts {
            usleep(Self.axWriteVerificationPollIntervalMicroseconds)
            let afterSnapshot = readCurrentInputTextSnapshot()
            let verification = Self.evaluatePasteVerification(
                insertedText: insertedText,
                replaceSelection: replaceSelection,
                targetProcessID: targetProcessID,
                before: beforeSnapshot.isEditable ? beforeSnapshot : nil,
                after: afterSnapshot
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
                return .success
            case .failure, .indeterminate:
                lastReadback = verification
            }
        }

        return lastReadback
    }

    func setTextViaPaste(
        _ text: String,
        replaceSelection: Bool,
        contextAlreadyRestored: Bool = false
    ) throws {
        guard !replaceSelection else {
            throw selectionReplacementError(
                code: 32,
                description: "External selection replacement requires a captured target"
            )
        }

        let pasteboard = NSPasteboard.general
        guard let previousSnapshot = capturePasteboardSnapshotWithTimeout(from: pasteboard) else {
            throw NSError(
                domain: "AXTextInjector",
                code: 16,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to preserve the current clipboard before paste"
                ]
            )
        }
        let strictFallbackEnabled = settingsStore?.strictEditApplyFallbackEnabled ?? false
        let stubbornPasteFallbackEnabled = settingsStore?.stubbornPasteFallbackEnabled ?? false
        let replacementContext = replaceSelection ? activeSelectionContext() : nil

        let targetPID: pid_t?
        if let context = replacementContext {
            targetPID = context.processID
            if !contextAlreadyRestored {
                restoreSelectionContext(context)
            }
        } else {
            targetPID = frontmostProcessID()
        }

        if Self.shouldActivateTargetBeforePaste(
            flagEnabled: stubbornPasteFallbackEnabled,
            targetProcessID: targetPID,
            frontmostProcessID: frontmostProcessID()
        ) {
            activateTargetProcess(targetPID)
        }

        let dispatchMethod = Self.pasteEventDispatchMethod(
            flagEnabled: stubbornPasteFallbackEnabled,
            targetProcessID: targetPID
        )

        if !replaceSelection {
            guard pasteboard.changeCount == previousSnapshot.changeCount else {
                throw NSError(
                    domain: "AXTextInjector",
                    code: 17,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The clipboard changed before paste could begin"
                    ]
                )
            }
            guard writeTransientPasteboardString(text, to: pasteboard) else {
                throw NSError(
                    domain: "AXTextInjector",
                    code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to prepare text for paste"]
                )
            }
            let injectionChangeCount = pasteboard.changeCount
            dispatchPasteShortcut(method: dispatchMethod, targetPID: targetPID)
            restorePasteboardAfterPaste(
                previousSnapshot,
                capturedChangeCount: injectionChangeCount,
                delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds
            )
            NetworkDebugLogger.logMessage("[Text Injection] eager paste dispatched")
            return
        }

        let targetElement = focusedElement()
        let initialSnapshot = readCurrentInputTextSnapshot()
        guard focusedElementMatches(targetElement) else {
            throw NSError(
                domain: "AXTextInjector",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Focused target changed before paste dispatch"]
            )
        }
        let beforeSnapshot = initialSnapshot.isEditable ? initialSnapshot : nil
        let allowClipboardSelectionFallback =
            Self.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
                replaceSelection: replaceSelection,
                selectionSource: replacementContext?.source,
                focusMatched: replacementContext?.isFocusedTarget ?? false,
                baselineAvailable: beforeSnapshot != nil
            )

        NetworkDebugLogger.logMessage(
            """
            [Text Injection] paste start
            replaceSelection: \(replaceSelection)
            strictFallbackEnabled: \(strictFallbackEnabled)
            stubbornPasteFallbackEnabled: \(stubbornPasteFallbackEnabled)
            dispatchMethod: \(dispatchMethod)
            targetPID: \(targetPID.map(String.init) ?? "nil")
            contextAlreadyRestored: \(contextAlreadyRestored)
            initialSnapshot: \(snapshotSummary(initialSnapshot))
            verificationBaseline: \(beforeSnapshot.map(snapshotSummary) ?? "<nil>")
            allowClipboardSelectionReplacementWithoutAXBaseline: \(allowClipboardSelectionFallback)
            """
        )

        if replaceSelection,
           strictFallbackEnabled,
           beforeSnapshot == nil,
           !allowClipboardSelectionFallback {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste aborted because replacement target is not verifiable"
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Replacement target is not a verifiable editable input."
                ]
            )
        }

        let deliveryProbe = PasteboardDeliveryProbe(text: text)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(deliveryProbe, forTypes: [.string])
        pasteboardItem.setData(Data(), forType: Self.transientPasteboardType)
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem])
        activePasteboardDeliveryProbe = deliveryProbe

        deliveryProbe.markDispatched()
        dispatchPasteShortcut(method: dispatchMethod, targetPID: targetPID)

        if allowClipboardSelectionFallback {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste verification skipped because clipboard-backed selection cannot provide AX baseline"
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds
            )
            return
        }

        guard Self.shouldAttemptPasteVerification(
            replaceSelection: replaceSelection,
            strictFallbackEnabled: strictFallbackEnabled
        ) else {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste verification skipped (replaceSelection=\(replaceSelection), strictFallbackEnabled=\(strictFallbackEnabled))"
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds
            )
            return
        }

        try verifyPasteInsertion(
            text: text,
            replaceSelection: replaceSelection,
            targetPID: targetPID,
            beforeSnapshot: beforeSnapshot,
            previousSnapshot: previousSnapshot,
            deliveryProbe: deliveryProbe,
            targetElement: targetElement
        )
    }

    private func dispatchPasteShortcut(method: PasteDispatchMethod, targetPID: pid_t?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        switch method {
        case .postToPid:
            if let targetPID {
                vDown?.postToPid(targetPID)
                vUp?.postToPid(targetPID)
            } else {
                vDown?.post(tap: .cghidEventTap)
                vUp?.post(tap: .cghidEventTap)
            }
        case .hidTap:
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
        }
    }

    private func verifyPasteInsertion(
        text: String,
        replaceSelection: Bool,
        targetPID: pid_t?,
        beforeSnapshot: CurrentInputTextSnapshot?,
        previousSnapshot: PasteboardSnapshot,
        deliveryProbe: PasteboardDeliveryProbe,
        targetElement: AXUIElement?
    ) throws {
        var lastReadback: PasteVerificationResult = .indeterminate
        var targetStableThroughout = true
        for attempt in 0 ..< Self.pasteVerificationAttempts {
            let payloadWasAlreadyObserved = deliveryProbe.wasRequestedAfterDispatch
            let remainedStable = waitForPasteEvidence(
                microseconds: Self.pasteVerificationPollIntervalMicroseconds,
                targetProcessID: targetPID,
                targetElement: targetElement,
                deliveryProbe: deliveryProbe,
                stopWhenPayloadRequested: !payloadWasAlreadyObserved
            )
            if !remainedStable {
                targetStableThroughout = false
            }
            let afterSnapshot = readCurrentInputTextSnapshot()
            let verification = Self.evaluatePasteVerification(
                insertedText: text,
                replaceSelection: replaceSelection,
                targetProcessID: targetPID,
                before: beforeSnapshot,
                after: afterSnapshot
            )
            lastReadback = verification
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
                if targetStableThroughout {
                    restorePasteboardAfterPaste(
                        previousSnapshot,
                        delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds
                    )
                    return
                }
            case let .failure(reason):
                logger.debug(
                    "paste verification failed on attempt \(attempt + 1, privacy: .public): \(reason, privacy: .public)"
                )
            case .indeterminate:
                if targetStableThroughout, deliveryProbe.wasRequestedAfterDispatch {
                    restorePasteboardAfterPaste(
                        previousSnapshot,
                        delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds
                    )
                    return
                }
                logger.debug("paste verification indeterminate on attempt \(attempt + 1, privacy: .public)")
            }
        }

        let currentPID = frontmostProcessID()
        if let targetPID, currentPID != targetPID {
            targetStableThroughout = false
        }
        if !focusedElementMatches(targetElement) {
            targetStableThroughout = false
        }
        let finalVerification = Self.finalPasteVerification(
            lastReadback: lastReadback,
            payloadRequestedAfterDispatch: deliveryProbe.wasRequestedAfterDispatch,
            payloadRequestedBeforeDispatch: deliveryProbe.wasRequestedBeforeDispatch,
            targetStableThroughout: targetStableThroughout
        )

        switch finalVerification {
        case .success:
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste committed via verified readback or post-dispatch payload request"
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.verifiedPasteRestoreDelayNanoseconds
            )
            return
        case let .failure(reason):
            let finalSnapshot = readCurrentInputTextSnapshot()
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] paste verification exhausted
                failureReason: \(reason)
                finalSnapshot: \(snapshotSummary(finalSnapshot))
                """
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Paste insertion could not be verified: \(reason)"
                ]
            )
        case .indeterminate:
            preconditionFailure("finalPasteVerification must return a terminal result")
        }
    }

    private func waitForPasteEvidence(
        microseconds: useconds_t,
        targetProcessID: pid_t?,
        targetElement: AXUIElement?,
        deliveryProbe: PasteboardDeliveryProbe,
        stopWhenPayloadRequested: Bool
    ) -> Bool {
        func targetIsStable() -> Bool {
            if let targetProcessID, frontmostProcessID() != targetProcessID {
                return false
            }
            return focusedElementMatches(targetElement)
        }

        let deadline = Date().addingTimeInterval(Double(microseconds) / 1_000_000)
        let pollInterval: TimeInterval = 0.01
        while Date() < deadline {
            guard targetIsStable() else { return false }
            if stopWhenPayloadRequested, deliveryProbe.wasRequestedAfterDispatch {
                return true
            }

            if Thread.isMainThread {
                let nextPoll = min(deadline, Date().addingTimeInterval(pollInterval))
                _ = RunLoop.current.run(mode: .default, before: nextPoll)
            } else {
                usleep(useconds_t(pollInterval * 1_000_000))
            }
        }
        return targetIsStable()
    }

    static func evaluatePasteVerification(
        insertedText: String,
        replaceSelection: Bool,
        targetProcessID: pid_t?,
        before: CurrentInputTextSnapshot?,
        after: CurrentInputTextSnapshot
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

            if let beforeText = before?.text,
               let beforeRange = before?.selectedRange,
               let expectedText = replacingUTF16Range(
                   in: beforeText,
                   range: beforeRange,
                   with: insertedText
               ),
               afterText == expectedText {
                return .success
            }

            if before?.text == nil,
               !normalizedInsertedText.isEmpty,
               normalizedAfterText.contains(normalizedInsertedText) {
                return .success
            }

            if let beforeText = before?.text {
                if beforeText == afterText {
                    if !after.isFocusedTarget || before?.isFocusedTarget == false {
                        return .indeterminate
                    }
                    if !replaceSelection,
                       before?.textSource == "ax-value",
                       after.textSource == "ax-value",
                       (
                           normalizedAfterText.isEmpty
                               || browserAutomationKind(for: before?.bundleIdentifier) != nil
                       ) {
                        return .indeterminate
                    }
                    return .failure("input-text-unchanged")
                }
            } else if replaceSelection,
                      !normalizedInsertedText.isEmpty,
                      normalizedAfterText != normalizedInsertedText {
                return .indeterminate
            }
        }

        if let reason = after.failureReason, reason == "accessibility-not-trusted" {
            return .failure(reason)
        }

        if let reason = after.failureReason, reason == "focused-element-not-editable" {
            if !replaceSelection, before == nil {
                return .indeterminate
            }
            return .failure(reason)
        }

        return .indeterminate
    }

    func readSelectedTextViaCopy(processID: pid_t?, milliseconds: Int) -> String? {
        let processScopedResult = readSelectedTextViaCopy(
            milliseconds: milliseconds,
            pasteboard: .general,
            sendCopy: { sendCopyShortcut(to: processID) }
        )
        if let processScopedResult {
            return processScopedResult
        }

        guard let processID, frontmostProcessID() == processID else { return nil }
        NetworkDebugLogger.logMessage(
            "[Text Selection] process-scoped copy did not respond; retrying through HID event tap"
        )
        return readSelectedTextViaCopy(
            milliseconds: milliseconds,
            pasteboard: .general,
            sendCopy: { sendCopyShortcutViaHID() }
        )
    }

    func readSelectedTextViaCopy(
        milliseconds: Int,
        pasteboard: NSPasteboard,
        sendCopy: () -> Void
    ) -> String? {
        guard let previousSnapshot = capturePasteboardSnapshotWithTimeout(from: pasteboard) else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard-copy skipped because the clipboard could not be preserved"
            )
            return nil
        }
        guard pasteboard.changeCount == previousSnapshot.changeCount else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard-copy skipped because the clipboard changed before probing"
            )
            return nil
        }

        let probeType = NSPasteboard.PasteboardType("ai.gulu.app.typeflux.selection-probe")
        pasteboard.clearContents()
        guard pasteboard.setData(Data(UUID().uuidString.utf8), forType: probeType) else {
            restorePasteboardIfUnchanged(
                previousSnapshot,
                to: pasteboard,
                expectedChangeCount: pasteboard.changeCount
            )
            return nil
        }

        var transactionChangeCount = pasteboard.changeCount
        defer {
            restorePasteboardIfUnchanged(
                previousSnapshot,
                to: pasteboard,
                expectedChangeCount: transactionChangeCount
            )
        }

        sendCopy()

        let timeout = Date().addingTimeInterval(Double(milliseconds) / 1000.0)
        while Date() < timeout {
            if pasteboard.changeCount != transactionChangeCount {
                transactionChangeCount = pasteboard.changeCount
                let copiedText = readPasteboardStringWithTimeout(from: pasteboard)
                let trimmed = copiedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            usleep(10000)
        }

        return nil
    }

    func restorePasteboardIfUnchanged(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) {
        guard pasteboard.changeCount == expectedChangeCount else {
            NetworkDebugLogger.logMessage(
                "[Text Selection] clipboard restore skipped because it changed after probing"
            )
            return
        }
        restorePasteboard(snapshot, to: pasteboard)
    }

    /// Pasteboard owners can provide data lazily and may block indefinitely. Read on a
    /// dedicated serial queue so a broken provider cannot freeze Typeflux's main thread.
    /// Once that queue is wedged, later reads still time out without creating more workers.
    func readPasteboardStringWithTimeout(from pasteboard: NSPasteboard) -> String? {
        let result = LockedPasteboardStringResult()
        let completed = DispatchSemaphore(value: 0)
        let pasteboardReference = UncheckedSendableReference(pasteboard)
        pasteboardReadQueue.async {
            result.store(pasteboardReference.value.string(forType: .string))
            completed.signal()
        }
        guard completed.wait(
            timeout: .now() + .milliseconds(Self.pasteboardReadTimeoutMilliseconds)
        ) == .success else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard string read timed out")
            return nil
        }
        return result.load()
    }

    func activateTargetProcess(_ processID: pid_t?) {
        guard let processID,
              let app = NSRunningApplication(processIdentifier: processID)
        else { return }

        app.activate(options: [.activateIgnoringOtherApps])

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            usleep(50000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                return
            }
        }
    }

    func sendCopyShortcut(to processID: pid_t?) {
        postCopyShortcut { event in
            if let processID {
                event.postToPid(processID)
            } else {
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func sendCopyShortcutViaHID() {
        postCopyShortcut { $0.post(tap: .cghidEventTap) }
    }

    private func postCopyShortcut(post: (CGEvent) -> Void) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: true
        )
        down?.flags = .maskCommand
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: false
        )
        up?.flags = .maskCommand

        if let down { post(down) }
        if let up { post(up) }
    }

    func capturePasteboardSnapshotWithTimeout(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let result = LockedPasteboardSnapshotResult()
        let completed = DispatchSemaphore(value: 0)
        let pasteboardReference = UncheckedSendableReference(pasteboard)
        pasteboardSnapshotQueue.async {
            result.store(Self.capturePasteboardSnapshot(
                from: pasteboardReference.value,
                maximumBytes: Self.maximumPasteboardSnapshotBytes
            ))
            completed.signal()
        }
        guard completed.wait(
            timeout: .now() + .milliseconds(Self.pasteboardSnapshotTimeoutMilliseconds)
        ) == .success else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard snapshot timed out")
            return nil
        }
        guard let snapshot = result.load() else {
            NetworkDebugLogger.logMessage("[Text Injection] pasteboard snapshot exceeded size limit")
            return nil
        }
        return snapshot
    }

    static func capturePasteboardSnapshot(
        from pasteboard: NSPasteboard,
        maximumBytes: Int
    ) -> PasteboardSnapshot? {
        guard maximumBytes >= 0 else { return nil }
        let initialChangeCount = pasteboard.changeCount
        var totalBytes = 0
        var capturedItems: [PasteboardItemSnapshot] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                guard data.count <= maximumBytes - totalBytes else { return nil }
                totalBytes += data.count
                representations.append((type: type, data: data))
            }
            capturedItems.append(PasteboardItemSnapshot(representations: representations))
        }

        guard pasteboard.changeCount == initialChangeCount else { return nil }
        return PasteboardSnapshot(changeCount: initialChangeCount, items: capturedItems)
    }

    func writeTransientPasteboardString(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: Self.transientPasteboardType)
        else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        activePasteboardDeliveryProbe = nil
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

    func restorePasteboardAfterPaste(
        _ previousSnapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard = .general,
        capturedChangeCount: Int? = nil,
        delayNanoseconds: UInt64
    ) {
        let pasteboardReference = UncheckedSendableReference(pasteboard)
        let expectedChangeCount = capturedChangeCount ?? pasteboard.changeCount
        Task.detached {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                let pasteboard = pasteboardReference.value
                let currentChangeCount = pasteboard.changeCount
                guard Self.shouldRestoreCapturedPasteboard(
                    capturedChangeCount: expectedChangeCount,
                    currentChangeCount: currentChangeCount
                ) else {
                    NetworkDebugLogger.logMessage(
                        "[Text Injection] pasteboard restore skipped; changeCount moved \(expectedChangeCount) → \(currentChangeCount)"
                    )
                    return
                }
                self.restorePasteboard(previousSnapshot, to: pasteboard)
            }
        }
    }
}

// swiftlint:enable identifier_name line_length
// swiftlint:enable closure_parameter_position file_length function_body_length
