import AppKit
import ApplicationServices
import Foundation

// swiftlint:disable closure_parameter_position file_length function_body_length
// swiftlint:disable identifier_name line_length opening_brace trailing_comma
extension AXTextInjector {
    func setText(_ text: String, replaceSelection: Bool) throws {
        if !AXIsProcessTrusted() {
            if !Self.didRequestAccessibility {
                Self.didRequestAccessibility = true
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                ) {
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
            """,
        )

        if replaceSelection, let context = activeSelectionContext() {
            NetworkDebugLogger.logMessage(
                "[Text Injection] restoring selection context before replace | \(selectionContextSummary(context))",
            )
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
                NetworkDebugLogger.logMessage(
                    "[Text Injection] replace completed via AX selected-text write",
                )
                latestSelectionContext = nil
                return
            }
            NetworkDebugLogger.logMessage(
                "[Text Injection] AX selected-text write unavailable or unverified, falling back",
            )
        }

        if let element = focusedElement(),
           try insertTextViaAX(
               text,
               into: element,
               replaceSelection: replaceSelection,
               selectionRange: nil,
               beforeSnapshot: beforeSnapshot,
           )
        {
            NetworkDebugLogger.logMessage("[Text Injection] completed via focused AX path")
            if replaceSelection {
                latestSelectionContext = nil
            }
            return
        }

        NetworkDebugLogger.logMessage("[Text Injection] falling back to paste path")
        try setTextViaPaste(
            text,
            replaceSelection: replaceSelection,
            contextAlreadyRestored: contextRestored,
        )
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
                logger.debug(
                    "AX selected text write reported success but could not be verified; falling back",
                )
                NetworkDebugLogger.logMessage(
                    """
                    [Text Injection] AX write verification failed
                    replaceSelection: \(replaceSelection)
                    beforeSnapshot: \(snapshotSummary(beforeSnapshot))
                    afterSnapshot: \(snapshotSummary(afterSnapshot))
                    """,
                )
            }
        }

        return false
    }

    func verifyAXWriteApplied(
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
                """,
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

    func setTextViaPaste(
        _ text: String,
        replaceSelection: Bool,
        contextAlreadyRestored: Bool = false,
    ) throws {
        let pasteboard = NSPasteboard.general
        let previousSnapshot = capturePasteboardSnapshot(from: pasteboard)
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
            frontmostProcessID: frontmostProcessID(),
        ) {
            activateTargetProcess(targetPID)
        }

        let dispatchMethod = Self.pasteEventDispatchMethod(
            flagEnabled: stubbornPasteFallbackEnabled,
            targetProcessID: targetPID,
        )

        let initialSnapshot = readCurrentInputTextSnapshot()
        let beforeSnapshot = initialSnapshot.isEditable ? initialSnapshot : nil
        let allowClipboardSelectionFallback =
            Self.shouldAllowClipboardSelectionReplacementWithoutAXBaseline(
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
            stubbornPasteFallbackEnabled: \(stubbornPasteFallbackEnabled)
            dispatchMethod: \(dispatchMethod)
            targetPID: \(targetPID.map(String.init) ?? "nil")
            contextAlreadyRestored: \(contextAlreadyRestored)
            initialSnapshot: \(snapshotSummary(initialSnapshot))
            verificationBaseline: \(beforeSnapshot.map(snapshotSummary) ?? "<nil>")
            allowClipboardSelectionReplacementWithoutAXBaseline: \(allowClipboardSelectionFallback)
            """,
        )

        if replaceSelection,
           strictFallbackEnabled,
           beforeSnapshot == nil,
           !allowClipboardSelectionFallback
        {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste aborted because replacement target is not verifiable",
            )
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

        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand

        switch dispatchMethod {
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

        if allowClipboardSelectionFallback {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste verification skipped because clipboard-backed selection cannot provide AX baseline",
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds,
            )
            return
        }

        guard Self.shouldPerformStrictPasteVerification(
            replaceSelection: replaceSelection,
            strictFallbackEnabled: strictFallbackEnabled,
        ) else {
            NetworkDebugLogger.logMessage(
                "[Text Injection] paste verification skipped (replaceSelection=\(replaceSelection), strictFallbackEnabled=\(strictFallbackEnabled))",
            )
            restorePasteboardAfterPaste(
                previousSnapshot,
                delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds,
            )
            return
        }

        try verifyPasteInsertion(
            text: text,
            replaceSelection: replaceSelection,
            targetPID: targetPID,
            beforeSnapshot: beforeSnapshot,
            previousSnapshot: previousSnapshot,
        )
    }

    private func verifyPasteInsertion(
        text: String,
        replaceSelection: Bool,
        targetPID: pid_t?,
        beforeSnapshot: CurrentInputTextSnapshot?,
        previousSnapshot: PasteboardSnapshot,
    ) throws {
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
                """,
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
                logger.debug("paste verification indeterminate on attempt \(attempt + 1, privacy: .public)")
            }
        }

        restorePasteboardAfterPaste(
            previousSnapshot,
            delayNanoseconds: Self.unverifiedPasteRestoreDelayNanoseconds,
        )

        if let lastFailureReason {
            let finalSnapshot = readCurrentInputTextSnapshot()
            NetworkDebugLogger.logMessage(
                """
                [Text Injection] paste verification exhausted
                lastFailureReason: \(lastFailureReason)
                finalSnapshot: \(snapshotSummary(finalSnapshot))
                """,
            )
            throw NSError(
                domain: "AXTextInjector",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Paste insertion could not be verified: \(lastFailureReason)",
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
                    if !after.isFocusedTarget || before?.isFocusedTarget == false {
                        return .indeterminate
                    }
                    return .failure("input-text-unchanged")
                }
            } else if replaceSelection,
                      !normalizedInsertedText.isEmpty,
                      normalizedAfterText != normalizedInsertedText
            {
                return .indeterminate
            }
        }

        if let reason = after.failureReason,
           reason == "focused-element-not-editable" || reason == "accessibility-not-trusted"
        {
            if !replaceSelection, before == nil {
                return .indeterminate
            }
            return .failure(reason)
        }

        return .indeterminate
    }

    func readSelectedTextViaCopy(processID: pid_t?, milliseconds: Int) -> String? {
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
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            usleep(10000)
        }

        restorePasteboardAfterPaste(
            previousSnapshot,
            delayNanoseconds: Self.legacyPasteRestoreDelayNanoseconds,
        )
        return nil
    }

    func activateTargetProcess(_ processID: pid_t?) {
        guard let processID,
              let app = NSRunningApplication(processIdentifier: processID)
        else { return }

        app.activate(options: [.activateIgnoringOtherApps])

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            usleep(50_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processID {
                return
            }
        }
    }

    func sendCopyShortcut(to processID: pid_t?) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: true,
        )
        down?.flags = .maskCommand
        let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: Self.copyShortcutKeyCode,
            keyDown: false,
        )
        up?.flags = .maskCommand

        if let processID {
            down?.postToPid(processID)
            up?.postToPid(processID)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func capturePasteboardSnapshot(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            let representations = item.types.compactMap {
                type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type, data: data)
            }
            return PasteboardItemSnapshot(representations: representations)
        }
        return PasteboardSnapshot(items: items)
    }

    func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
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
        delayNanoseconds: UInt64,
    ) {
        let capturedChangeCount = NSPasteboard.general.changeCount
        Task.detached {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                let currentChangeCount = pasteboard.changeCount
                guard Self.shouldRestoreCapturedPasteboard(
                    capturedChangeCount: capturedChangeCount,
                    currentChangeCount: currentChangeCount,
                ) else {
                    NetworkDebugLogger.logMessage(
                        "[Text Injection] pasteboard restore skipped; changeCount moved \(capturedChangeCount) → \(currentChangeCount)",
                    )
                    return
                }
                self.restorePasteboard(previousSnapshot, to: pasteboard)
            }
        }
    }
}

// swiftlint:enable identifier_name line_length opening_brace trailing_comma
// swiftlint:enable closure_parameter_position file_length function_body_length
