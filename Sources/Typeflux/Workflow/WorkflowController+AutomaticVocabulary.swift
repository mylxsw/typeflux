import Foundation

/// Snapshot of a currently running automatic-vocabulary observation. Lives on
/// `WorkflowController` so an incoming schedule can finalize (run analysis with
/// whatever has been observed so far) before the previous task is cancelled.
struct AutomaticVocabularyActiveSession {
    let sessionID: UUID
    let insertedText: String
    var baselineText: String?
    var latestObservedText: String?
    var hasObservedChange: Bool
}

extension WorkflowController {
    struct AutomaticVocabularyExpectedApp: Equatable {
        let bundleIdentifier: String?
        let processID: pid_t?
        let processName: String?
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func scheduleAutomaticVocabularyObservation(for insertedText: String) {
        // If a previous observation is still running and has seen user edits, try
        // to finalize it before starting the new one. Otherwise the user's
        // follow-up dictation silently throws away a partially observed session.
        finalizePreviousAutomaticVocabularySessionIfNeeded()
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil
        automaticVocabularyActiveSession = nil

        guard settingsStore.automaticVocabularyCollectionEnabled else {
            logAutomaticVocabulary("skip scheduling: feature disabled")
            return
        }

        let normalizedInsertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInsertedText.isEmpty else {
            logAutomaticVocabulary("skip scheduling: inserted text empty after normalization")
            return
        }

        let sessionID = UUID()
        automaticVocabularyActiveSession = AutomaticVocabularyActiveSession(
            sessionID: sessionID,
            insertedText: normalizedInsertedText,
            baselineText: nil,
            latestObservedText: nil,
            hasObservedChange: false,
        )
        logAutomaticVocabulary(
            "session scheduled | session=\(shortSessionID(sessionID)) "
                + "| insertedText=\(automaticVocabularyPreview(normalizedInsertedText)) "
                + "| observationWindow=\(Int(Self.automaticVocabularyObservationWindow))s "
                + "| idleSettleDelay=\(Self.automaticVocabularyIdleSettleDelay)s",
        )

        automaticVocabularyObservationTask = Task { [weak self] in
            guard let self else { return }

            guard let initialSnapshot = await readInitialEditableSnapshot(sessionID: sessionID) else {
                clearActiveAutomaticVocabularySession(for: sessionID)
                return
            }
            let expectedApp = automaticVocabularyExpectedApp(from: initialSnapshot)

            do {
                try await Task.sleep(for: Self.automaticVocabularyStartupDelay)
            } catch {
                logAutomaticVocabulary("session cancelled before startup delay finished | session=\(shortSessionID(sessionID))")
                return
            }

            guard !Task.isCancelled else { return }
            let baselineSnapshot = await readAutomaticVocabularyBaselineWithRetry(
                expectedSubstring: normalizedInsertedText,
            )
            guard let baselineText = baselineSnapshot.text else {
                logAutomaticVocabulary(
                    "session aborted: failed to read baseline input text | session=\(shortSessionID(sessionID)) | "
                        + describeCurrentInputTextSnapshot(baselineSnapshot),
                )
                clearActiveAutomaticVocabularySession(for: sessionID)
                return
            }
            guard automaticVocabularyMatchesExpectedApp(baselineSnapshot, expectedApp: expectedApp) else {
                logAutomaticVocabulary(
                    "session aborted: focused app changed before baseline was captured | session=\(shortSessionID(sessionID)) | expected="
                        + describeAutomaticVocabularyExpectedApp(expectedApp)
                        + " | actual="
                        + describeCurrentInputTextSnapshot(baselineSnapshot),
                )
                clearActiveAutomaticVocabularySession(for: sessionID)
                return
            }

            updateActiveAutomaticVocabularySession(sessionID: sessionID) { session in
                session.baselineText = baselineText
                session.latestObservedText = baselineText
            }

            var observationState = AutomaticVocabularyMonitor.makeObservationState(
                baselineText: baselineText,
                startedAt: Date(),
            )
            logAutomaticVocabulary(
                "session started | session=\(shortSessionID(sessionID)) "
                    + "| baselineText=\(automaticVocabularyPreview(baselineText))",
            )
            let deadline = Date().addingTimeInterval(Self.automaticVocabularyObservationWindow)
            var exitReason: AutomaticVocabularySessionExit = .deadlineReached

            pollingLoop: while true {
                let now = Date()
                if now >= deadline {
                    exitReason = .deadlineReached
                    break pollingLoop
                }

                do {
                    try await Task.sleep(for: Self.automaticVocabularyPollInterval)
                } catch {
                    logAutomaticVocabulary("session cancelled during polling | session=\(shortSessionID(sessionID))")
                    return
                }

                guard !Task.isCancelled else { return }
                let currentSnapshot = await textInjector.currentInputTextSnapshot()
                guard let currentText = currentSnapshot.text else {
                    logAutomaticVocabulary(
                        "poll skipped: failed to read current input text | session=\(shortSessionID(sessionID)) | "
                            + describeCurrentInputTextSnapshot(currentSnapshot),
                    )
                    continue pollingLoop
                }
                guard automaticVocabularyMatchesExpectedApp(currentSnapshot, expectedApp: expectedApp) else {
                    logAutomaticVocabulary(
                        "session aborted: focused app changed during observation | session=\(shortSessionID(sessionID)) | expected="
                            + describeAutomaticVocabularyExpectedApp(expectedApp)
                            + " | actual="
                            + describeCurrentInputTextSnapshot(currentSnapshot),
                    )
                    clearActiveAutomaticVocabularySession(for: sessionID)
                    return
                }

                let pollAt = Date()
                let didChange = AutomaticVocabularyMonitor.observe(
                    text: currentText,
                    at: pollAt,
                    state: &observationState,
                )
                if didChange {
                    updateActiveAutomaticVocabularySession(sessionID: sessionID) { session in
                        session.latestObservedText = currentText
                        session.hasObservedChange = true
                    }
                    logAutomaticVocabulary(
                        "change observed | session=\(shortSessionID(sessionID)) "
                            + "| latestText=\(automaticVocabularyPreview(currentText))",
                    )
                }

                if AutomaticVocabularyMonitor.shouldTriggerAnalysis(
                    state: observationState,
                    now: pollAt,
                    idleSettleDelay: Self.automaticVocabularyIdleSettleDelay,
                ) {
                    exitReason = .settled
                    break pollingLoop
                }
            }

            logAutomaticVocabulary(
                "observation finished | session=\(shortSessionID(sessionID)) "
                    + "| reason=\(exitReason) "
                    + "| finalText=\(automaticVocabularyPreview(observationState.latestObservedText))",
            )

            clearActiveAutomaticVocabularySession(for: sessionID)
            await runAutomaticVocabularyAnalysis(
                sessionID: sessionID,
                insertedText: normalizedInsertedText,
                baselineText: observationState.baselineText,
                finalText: observationState.latestObservedText,
            )
        }
    }

    func runAutomaticVocabularyAnalysis(
        sessionID: UUID = UUID(),
        insertedText: String,
        baselineText: String,
        finalText: String,
    ) async {
        guard finalText != baselineText else {
            logAutomaticVocabulary("analysis skipped: final text unchanged from baseline | session=\(shortSessionID(sessionID))")
            return
        }

        guard let change = AutomaticVocabularyMonitor.detectChange(
            from: baselineText,
            to: finalText,
        ) else {
            logAutomaticVocabulary("analysis skipped: no candidate terms found after diff | session=\(shortSessionID(sessionID))")
            return
        }

        if AutomaticVocabularyMonitor.changeIsJustInitialInsertion(
            change: change,
            insertedText: insertedText,
        ) {
            logAutomaticVocabulary("analysis skipped: change resembles initial text insertion | session=\(shortSessionID(sessionID))")
            return
        }

        if AutomaticVocabularyMonitor.isEditTooLarge(
            inserted: insertedText,
            baseline: baselineText,
            final: finalText,
            ratioLimit: Self.automaticVocabularyEditRatioLimit,
        ) {
            let ratio = AutomaticVocabularyMonitor.editRatio(
                inserted: insertedText,
                baseline: baselineText,
                final: finalText,
            )
            logAutomaticVocabulary(
                "analysis skipped: edit too large | session=\(shortSessionID(sessionID)) "
                    + "| editRatio=\(String(format: "%.2f", ratio)) "
                    + "| insertedLen=\(insertedText.count) "
                    + "| baselineLen=\(baselineText.count) | finalLen=\(finalText.count)",
            )
            return
        }

        let candidateSummary = change.candidateTerms.joined(separator: ", ")
        logAutomaticVocabulary(
            "diff detected | session=\(shortSessionID(sessionID)) "
                + "| oldFragment=\(automaticVocabularyPreview(change.oldFragment)) "
                + "| newFragment=\(automaticVocabularyPreview(change.newFragment)) "
                + "| candidates=\(candidateSummary)",
        )

        let configStatus = await validateLLMConfiguration()
        guard case .ready = configStatus else {
            logAutomaticVocabulary(
                "analysis skipped: llm not configured | session=\(shortSessionID(sessionID))",
            )
            return
        }

        do {
            let acceptedTerms = try await evaluateAutomaticVocabularyCandidates(
                transcript: insertedText,
                change: change,
            )
            let approvedSummary = acceptedTerms.joined(separator: ", ")
            logAutomaticVocabulary("llm decision received | session=\(shortSessionID(sessionID)) | approvedTerms=\(approvedSummary)")
            let addedTerms = addAutomaticVocabularyTerms(acceptedTerms)
            guard !addedTerms.isEmpty else {
                logAutomaticVocabulary("analysis completed: no new terms added | session=\(shortSessionID(sessionID))")
                return
            }

            let addedSummary = addedTerms.joined(separator: ", ")
            logAutomaticVocabulary("terms added | session=\(shortSessionID(sessionID)) | addedTerms=\(addedSummary)")

            await MainActor.run {
                self.overlayController.showNotice(
                    message: self.automaticVocabularyNotice(for: addedTerms),
                )
            }
        } catch {
            logAutomaticVocabulary("analysis failed | session=\(shortSessionID(sessionID)) | error=\(error.localizedDescription)")
            ErrorLogStore.shared.log(
                "Automatic vocabulary evaluation failed: \(error.localizedDescription)",
            )
        }
    }

    private func readInitialEditableSnapshot(sessionID: UUID) async -> CurrentInputTextSnapshot? {
        var latestSnapshot = await textInjector.currentInputTextSnapshot()
        if latestSnapshot.isEditable {
            return latestSnapshot
        }

        for attempt in 1 ... Self.automaticVocabularyInitialSnapshotRetryCount {
            logAutomaticVocabulary(
                "initial snapshot not editable, retrying \(attempt)/\(Self.automaticVocabularyInitialSnapshotRetryCount) "
                    + "| session=\(shortSessionID(sessionID)) | "
                    + describeCurrentInputTextSnapshot(latestSnapshot),
            )

            do {
                try await Task.sleep(for: Self.automaticVocabularyInitialSnapshotRetryDelay)
            } catch {
                return nil
            }

            latestSnapshot = await textInjector.currentInputTextSnapshot()
            if latestSnapshot.isEditable {
                return latestSnapshot
            }
        }

        logAutomaticVocabulary(
            "session aborted: context is not editable after retry | session=\(shortSessionID(sessionID)) | "
                + describeCurrentInputTextSnapshot(latestSnapshot),
        )
        return nil
    }

    func evaluateAutomaticVocabularyCandidates(
        transcript: String,
        change: AutomaticVocabularyChange,
    ) async throws -> [String] {
        let prompts = PromptCatalog.automaticVocabularyDecisionPrompts(
            transcript: transcript,
            oldFragment: change.oldFragment,
            newFragment: change.newFragment,
            candidateTerms: change.candidateTerms,
            existingTerms: VocabularyStore.allTerms(),
        )
        let response = try await llmService.completeJSON(
            systemPrompt: prompts.system,
            userPrompt: prompts.user,
            schema: AutomaticVocabularyMonitor.decisionSchema,
        )
        logAutomaticVocabulary("llm raw response | response=\(automaticVocabularyPreview(response))")
        return AutomaticVocabularyMonitor.parseAcceptedTerms(from: response)
    }

    func addAutomaticVocabularyTerms(_ terms: [String]) -> [String] {
        let existingTerms = Set(
            VocabularyStore.allTerms().map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            },
        )
        var knownTerms = existingTerms
        var addedTerms: [String] = []

        for rawTerm in terms {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = term.lowercased()
            guard !term.isEmpty, !knownTerms.contains(normalized) else { continue }
            _ = VocabularyStore.add(term: term, source: .automatic)
            knownTerms.insert(normalized)
            addedTerms.append(term)
        }

        return addedTerms
    }

    func automaticVocabularyNotice(for terms: [String]) -> String {
        if terms.count == 1, let term = terms.first {
            return L("workflow.vocabulary.autoAdded.single", term)
        }

        return L("workflow.vocabulary.autoAdded.multiple", terms.count)
    }

    func readAutomaticVocabularyBaselineWithRetry(
        expectedSubstring: String? = nil,
    ) async -> CurrentInputTextSnapshot {
        var latestSnapshot = await textInjector.currentInputTextSnapshot()
        if latestSnapshot.text != nil,
           automaticVocabularyBaselineContainsExpected(latestSnapshot.text, expected: expectedSubstring)
        {
            return latestSnapshot
        }

        for attempt in 1 ... Self.automaticVocabularyBaselineRetryCount {
            logAutomaticVocabulary(
                "baseline read retry \(attempt)/\(Self.automaticVocabularyBaselineRetryCount) | "
                    + describeCurrentInputTextSnapshot(latestSnapshot),
            )

            do {
                try await Task.sleep(for: Self.automaticVocabularyBaselineRetryDelay)
            } catch {
                return latestSnapshot
            }

            latestSnapshot = await textInjector.currentInputTextSnapshot()
            if latestSnapshot.text != nil,
               automaticVocabularyBaselineContainsExpected(latestSnapshot.text, expected: expectedSubstring)
            {
                logAutomaticVocabulary(
                    "baseline read recovered on retry \(attempt) | "
                        + describeCurrentInputTextSnapshot(latestSnapshot),
                )
                return latestSnapshot
            }
        }

        if latestSnapshot.text != nil {
            logAutomaticVocabulary(
                "baseline may be stale (expected substring missing) | "
                    + describeCurrentInputTextSnapshot(latestSnapshot),
            )
        }
        return latestSnapshot
    }

    private func automaticVocabularyBaselineContainsExpected(
        _ text: String?,
        expected: String?,
    ) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let text else { return false }
        let normalizedText = text.lowercased()
        let normalizedExpected = expected.lowercased()
        return normalizedText.contains(normalizedExpected)
    }

    func logAutomaticVocabulary(_ message: String) {
        NetworkDebugLogger.logMessage("[Auto Vocabulary] \(message)")
    }

    func shortSessionID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    func automaticVocabularyPreview(_ text: String, limit: Int = 80) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    func describeCurrentInputTextSnapshot(_ snapshot: CurrentInputTextSnapshot) -> String {
        let bundleIdentifier = snapshot.bundleIdentifier ?? "<unknown>"
        let processName = snapshot.processName ?? "<unknown>"
        let processID = snapshot.processID.map(String.init) ?? "<unknown>"
        let role = snapshot.role ?? "<unknown>"
        let textPreview = snapshot.text.map { automaticVocabularyPreview($0) } ?? "<nil>"
        let failureReason = snapshot.failureReason ?? "<none>"

        return "bundle=\(bundleIdentifier) | process=\(processName)(pid: \(processID)) | role=\(role) | "
            + "editable=\(snapshot.isEditable) | failureReason=\(failureReason) | text=\(textPreview)"
    }

    func automaticVocabularyExpectedApp(from snapshot: CurrentInputTextSnapshot) -> AutomaticVocabularyExpectedApp {
        AutomaticVocabularyExpectedApp(
            bundleIdentifier: normalizedAutomaticVocabularyAppField(snapshot.bundleIdentifier),
            processID: snapshot.processID,
            processName: normalizedAutomaticVocabularyAppField(snapshot.processName),
        )
    }

    func automaticVocabularyMatchesExpectedApp(
        _ snapshot: CurrentInputTextSnapshot,
        expectedApp: AutomaticVocabularyExpectedApp,
    ) -> Bool {
        if let expectedBundleIdentifier = expectedApp.bundleIdentifier,
           let actualBundleIdentifier = normalizedAutomaticVocabularyAppField(snapshot.bundleIdentifier)
        {
            return expectedBundleIdentifier == actualBundleIdentifier
        }

        if let expectedProcessID = expectedApp.processID,
           let actualProcessID = snapshot.processID
        {
            return expectedProcessID == actualProcessID
        }

        if let expectedProcessName = expectedApp.processName,
           let actualProcessName = normalizedAutomaticVocabularyAppField(snapshot.processName)
        {
            return expectedProcessName == actualProcessName
        }

        return true
    }

    func describeAutomaticVocabularyExpectedApp(_ expectedApp: AutomaticVocabularyExpectedApp) -> String {
        let bundleIdentifier = expectedApp.bundleIdentifier ?? "<unknown>"
        let processName = expectedApp.processName ?? "<unknown>"
        let processID = expectedApp.processID.map(String.init) ?? "<unknown>"
        return "bundle=\(bundleIdentifier) | process=\(processName)(pid: \(processID))"
    }

    func normalizedAutomaticVocabularyAppField(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    // MARK: - Active session state plumbing

    func updateActiveAutomaticVocabularySession(
        sessionID: UUID,
        mutate: (inout AutomaticVocabularyActiveSession) -> Void,
    ) {
        guard var session = automaticVocabularyActiveSession,
              session.sessionID == sessionID
        else {
            return
        }
        mutate(&session)
        automaticVocabularyActiveSession = session
    }

    func clearActiveAutomaticVocabularySession(for sessionID: UUID) {
        guard let session = automaticVocabularyActiveSession, session.sessionID == sessionID else {
            return
        }
        automaticVocabularyActiveSession = nil
    }

    /// Invoked at the top of `scheduleAutomaticVocabularyObservation`. If the
    /// previous session already observed a meaningful edit, we launch a detached
    /// analysis task using its last-known state instead of losing that work when
    /// the previous observation Task is cancelled below.
    func finalizePreviousAutomaticVocabularySessionIfNeeded() {
        guard let session = automaticVocabularyActiveSession,
              session.hasObservedChange,
              let baseline = session.baselineText,
              let latest = session.latestObservedText,
              baseline != latest
        else {
            return
        }

        let insertedText = session.insertedText
        let sessionID = session.sessionID
        logAutomaticVocabulary(
            "finalizing previous session before new observation "
                + "| session=\(shortSessionID(sessionID)) "
                + "| finalText=\(automaticVocabularyPreview(latest))",
        )

        Task.detached { [weak self] in
            guard let self else { return }
            await self.runAutomaticVocabularyAnalysis(
                sessionID: sessionID,
                insertedText: insertedText,
                baselineText: baseline,
                finalText: latest,
            )
        }
    }
}
