import Foundation

extension WorkflowController {
    func personaPickerTitle(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            L("overlay.personaPicker.switchTitle")
        case .applySelection:
            L("overlay.personaPicker.applyTitle")
        }
    }

    func personaPickerInstructions(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            L("overlay.personaPicker.switchInstructions")
        case .applySelection:
            L("overlay.personaPicker.applyInstructions")
        }
    }

    func personaPickerEntries(includeNoneOption: Bool) -> [PersonaPickerEntry] {
        var items: [PersonaPickerEntry] = []
        if includeNoneOption {
            items.append(
                PersonaPickerEntry(
                    id: nil,
                    title: L("persona.none.title"),
                    subtitle: L("persona.none.subtitle"),
                ),
            )
        }
        items.append(
            contentsOf: settingsStore.personas.map {
                PersonaPickerEntry(id: $0.id, title: $0.name, subtitle: $0.prompt)
            },
        )
        return items
    }

    func movePersonaSelection(delta: Int) {
        guard isPersonaPickerPresented, !personaPickerItems.isEmpty else { return }
        let maxIndex = personaPickerItems.count - 1
        personaPickerSelectedIndex = max(0, min(maxIndex, personaPickerSelectedIndex + delta))
        Task { @MainActor in
            self.overlayController.updatePersonaPickerSelection(self.personaPickerSelectedIndex)
        }
    }

    func confirmPersonaSelection() {
        guard isPersonaPickerPresented,
              personaPickerItems.indices.contains(personaPickerSelectedIndex)
        else { return }

        let selected = personaPickerItems[personaPickerSelectedIndex]
        let mode = personaPickerMode
        dismissPersonaPicker(closeOverlay: false)

        switch mode {
        case .switchDefault:
            settingsStore.applyPersonaSelection(selected.id)
            if selected.id != nil {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L("workflow.persona.switched", selected.title))
                }
            } else {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L("workflow.persona.switchedOff"))
                }
            }
        case let .applySelection(context):
            guard let personaID = selected.id,
                  let persona = settingsStore.personas.first(where: { $0.id == personaID })
            else { return }
            applyPersonaToSelection(context, persona: persona)
        }
    }

    func selectPersonaSelection(at index: Int) {
        guard isPersonaPickerPresented, personaPickerItems.indices.contains(index) else { return }
        personaPickerSelectedIndex = index
        confirmPersonaSelection()
    }

    func dismissPersonaPicker(closeOverlay: Bool = true) {
        guard isPersonaPickerPresented else { return }
        isPersonaPickerPresented = false
        personaPickerItems = []
        personaPickerSelectedIndex = 0
        personaPickerMode = .switchDefault
        guard closeOverlay else { return }
        Task { @MainActor in
            self.overlayController.dismiss(after: 0.05)
        }
    }

    // swiftlint:disable:next function_body_length
    func applyPersonaToSelection(_ context: PersonaSelectionContext, persona: PersonaProfile) {
        let personaPrompt = settingsStore.resolvedPersonaPrompt(for: persona).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personaPrompt.isEmpty else { return }

        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        let sessionID = beginProcessingSession()
        startProcessingTimeout(sessionID: sessionID)

        var record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: personaPrompt,
            selectionOriginalText: context.selectedText,
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .running,
            applyStatus: .pending,
        )
        saveHistoryRecord(record)
        activeProcessingRecordID = record.id

        Task { @MainActor in
            self.appState.setStatus(.processing)
            self.overlayController.showLLMProcessing()
        }

        let shouldShowResultDialog = shouldPresentResultDialog(for: context.snapshot)
        processingTask = Task { [weak self] in
            guard let self else { return }

            do {
                let rewriteResult = try await generateRewrite(
                    request: LLMRewriteRequest(
                        mode: .rewriteTranscript,
                        sourceText: context.selectedText,
                        spokenInstruction: nil,
                        personaPrompt: personaPrompt,
                        appSystemContext: AppSystemContext(snapshot: context.snapshot),
                    ),
                    sessionID: sessionID,
                    showsStreamingPreview: !shouldShowResultDialog,
                )
                try ensureProcessingIsActive(sessionID)

                record.selectionEditedText = rewriteResult.text
                record.processingStatus = .succeeded
                record.applyStatus = .running
                saveHistoryRecord(record)

                let outcome: ApplyOutcome
                if shouldShowResultDialog {
                    await MainActor.run {
                        self.lastDialogResultText = rewriteResult.text
                        self.overlayController.showResultDialog(
                            title: L("workflow.result.copyTitle"),
                            message: rewriteResult.text,
                        )
                    }
                    outcome = .presentedInDialog
                } else {
                    outcome = applyText(
                        rewriteResult.text,
                        replace: true,
                        fallbackTitle: L("workflow.result.copyTitle"),
                    )
                }

                try ensureProcessingIsActive(sessionID)
                record.applyStatus = .succeeded
                record.applyMessage = outcome.message
                saveHistoryRecord(record)
                UsageStatsStore.shared.recordSession(record: record)
                enforceHistoryRetentionPolicy()

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.appState.setStatus(.idle)
                        if !shouldShowResultDialog {
                            self.overlayController.dismissSoon()
                        }
                    }
                    self.processingTask = nil
                    self.activeProcessingRecordID = nil
                }
            } catch is CancellationError {
                markCancelled(&record)
                saveHistoryRecord(record)
                enforceHistoryRetentionPolicy()
                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.processingTask = nil
                        self.activeProcessingRecordID = nil
                    }
                }
            } catch {
                let msg = "Processing failed: \(error.localizedDescription)"
                ErrorLogStore.shared.log(msg)
                markFailure(&record, message: msg)
                saveHistoryRecord(record)
                UsageStatsStore.shared.recordSession(record: record)
                enforceHistoryRetentionPolicy()

                await MainActor.run {
                    if self.processingSessionID == sessionID {
                        self.soundEffectPlayer.play(.error)
                        self.appState.setStatus(.failed(message: L("workflow.processing.failed")))
                        self.overlayController.showFailure(message: msg)
                        self.overlayController.dismiss(after: 3.0)
                    }
                    self.processingTask = nil
                    self.activeProcessingRecordID = nil
                }
            }

            cancelProcessingTimeout()
        }
    }
}
