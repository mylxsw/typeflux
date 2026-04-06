import Foundation

extension WorkflowController {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func scheduleAutomaticVocabularyObservation(for insertedText: String) {
        automaticVocabularyObservationTask?.cancel()
        automaticVocabularyObservationTask = nil

        guard settingsStore.automaticVocabularyCollectionEnabled else {
            logAutomaticVocabulary("skip scheduling: feature disabled")
            return
        }

        let normalizedInsertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInsertedText.isEmpty else {
            logAutomaticVocabulary("skip scheduling: inserted text empty after normalization")
            return
        }

        logAutomaticVocabulary(
            "session scheduled | insertedText=\(automaticVocabularyPreview(normalizedInsertedText)) "
                + "| observationWindow=\(Int(Self.automaticVocabularyObservationWindow))s "
                + "| settleDelay=\(Self.automaticVocabularySettleDelay)s "
                + "| maxAnalyses=\(Self.automaticVocabularyMaxAnalysesPerSession)",
        )

        automaticVocabularyObservationTask = Task { [weak self] in
            guard let self else { return }

            let initialSnapshot = await self.textInjector.currentInputTextSnapshot()
            guard initialSnapshot.isEditable else {
                self.logAutomaticVocabulary(
                    "session aborted: context is not editable | "
                        + self.describeCurrentInputTextSnapshot(initialSnapshot)
                )
                return
            }

            do {
                try await Task.sleep(for: Self.automaticVocabularyStartupDelay)
            } catch {
                logAutomaticVocabulary("session cancelled before startup delay finished")
                return
            }

            guard !Task.isCancelled else { return }
            let baselineSnapshot = await readAutomaticVocabularyBaselineWithRetry()
            guard let baselineText = baselineSnapshot.text else {
                logAutomaticVocabulary(
                    "session aborted: failed to read baseline input text | "
                        + describeCurrentInputTextSnapshot(baselineSnapshot),
                )
                return
            }

            var observationState = AutomaticVocabularyMonitor.makeObservationState(
                baselineText: baselineText,
                startedAt: Date(),
            )
            logAutomaticVocabulary("session started | baselineText=\(automaticVocabularyPreview(baselineText))")
            let deadline = Date().addingTimeInterval(Self.automaticVocabularyObservationWindow)

            while Date() < deadline {
                do {
                    try await Task.sleep(for: Self.automaticVocabularyPollInterval)
                } catch {
                    logAutomaticVocabulary("session cancelled during polling")
                    return
                }

                guard !Task.isCancelled else { return }
                let currentSnapshot = await textInjector.currentInputTextSnapshot()
                guard let currentText = currentSnapshot.text else {
                    logAutomaticVocabulary(
                        "poll skipped: failed to read current input text | "
                            + describeCurrentInputTextSnapshot(currentSnapshot),
                    )
                    continue
                }

                let now = Date()
                let didChange = AutomaticVocabularyMonitor.observe(
                    text: currentText,
                    at: now,
                    state: &observationState,
                )
                if didChange {
                    logAutomaticVocabulary(
                        "change observed | analysisCount=\(observationState.analysisCount) "
                            + "| latestText=\(automaticVocabularyPreview(currentText))",
                    )
                }

                guard let pendingAnalysis = AutomaticVocabularyMonitor.pendingAnalysis(
                    state: observationState,
                    now: now,
                    settleDelay: Self.automaticVocabularySettleDelay,
                    maxAnalyses: Self.automaticVocabularyMaxAnalysesPerSession,
                ) else {
                    continue
                }

                AutomaticVocabularyMonitor.markAnalysisCompleted(
                    for: pendingAnalysis.updatedText,
                    state: &observationState,
                )
                logAutomaticVocabulary(
                    "stable change ready for analysis | analysisRound=\(observationState.analysisCount) "
                        + "| previous=\(automaticVocabularyPreview(pendingAnalysis.previousStableText)) "
                        + "| updated=\(automaticVocabularyPreview(pendingAnalysis.updatedText))",
                )

                guard let change = AutomaticVocabularyMonitor.detectChange(
                    from: pendingAnalysis.previousStableText,
                    to: pendingAnalysis.updatedText,
                ) else {
                    logAutomaticVocabulary("analysis skipped: no candidate terms found after diff")
                    continue
                }

                if change.newFragment == normalizedInsertedText {
                    logAutomaticVocabulary("analysis skipped: change resembles initial text insertion")
                    continue
                }

                let candidateSummary = change.candidateTerms.joined(separator: ", ")
                logAutomaticVocabulary(
                    "diff detected | oldFragment=\(automaticVocabularyPreview(change.oldFragment)) "
                        + "| newFragment=\(automaticVocabularyPreview(change.newFragment)) "
                        + "| candidates=\(candidateSummary)",
                )

                do {
                    let acceptedTerms = try await evaluateAutomaticVocabularyCandidates(
                        transcript: normalizedInsertedText,
                        change: change,
                    )
                    let approvedSummary = acceptedTerms.joined(separator: ", ")
                    logAutomaticVocabulary("llm decision received | approvedTerms=\(approvedSummary)")
                    let addedTerms = addAutomaticVocabularyTerms(acceptedTerms)
                    guard !addedTerms.isEmpty else {
                        logAutomaticVocabulary("analysis completed: no new terms added")
                        continue
                    }

                    let addedSummary = addedTerms.joined(separator: ", ")
                    logAutomaticVocabulary("terms added | addedTerms=\(addedSummary)")

                    await MainActor.run {
                        self.overlayController.showNotice(
                            message: self.automaticVocabularyNotice(for: addedTerms),
                        )
                    }
                } catch {
                    logAutomaticVocabulary("analysis failed: \(error.localizedDescription)")
                    ErrorLogStore.shared.log(
                        "Automatic vocabulary evaluation failed: \(error.localizedDescription)",
                    )
                }
            }

            logAutomaticVocabulary("session completed | totalAnalyses=\(observationState.analysisCount)")
        }
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
            existingTerms: VocabularyStore.activeTerms(),
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
            VocabularyStore.activeTerms().map {
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

    func readAutomaticVocabularyBaselineWithRetry() async -> CurrentInputTextSnapshot {
        var latestSnapshot = await textInjector.currentInputTextSnapshot()
        guard latestSnapshot.text == nil else { return latestSnapshot }

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
            if latestSnapshot.text != nil {
                logAutomaticVocabulary(
                    "baseline read recovered on retry \(attempt) | "
                        + describeCurrentInputTextSnapshot(latestSnapshot),
                )
                return latestSnapshot
            }
        }

        return latestSnapshot
    }

    func logAutomaticVocabulary(_ message: String) {
        NetworkDebugLogger.logMessage("[Auto Vocabulary] \(message)")
    }

    func automaticVocabularyPreview(_ text: String, limit: Int = 80) -> String {
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "..."
    }

    func describeCurrentInputTextSnapshot(_ snapshot: CurrentInputTextSnapshot) -> String {
        let processName = snapshot.processName ?? "<unknown>"
        let processID = snapshot.processID.map(String.init) ?? "<unknown>"
        let role = snapshot.role ?? "<unknown>"
        let textPreview = snapshot.text.map { automaticVocabularyPreview($0) } ?? "<nil>"
        let failureReason = snapshot.failureReason ?? "<none>"

        return "process=\(processName)(pid: \(processID)) | role=\(role) | "
            + "editable=\(snapshot.isEditable) | failureReason=\(failureReason) | text=\(textPreview)"
    }
}
