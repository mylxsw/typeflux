import AppKit
import Foundation

extension WorkflowController {
    func moveOverlayPickerSelection(delta: Int) {
        if isHistoryPickerPresented {
            moveHistorySelection(delta: delta)
            return
        }
        movePersonaSelection(delta: delta)
    }

    func selectOverlayPickerSelection(at index: Int) {
        if isHistoryPickerPresented {
            selectHistorySelection(at: index)
            return
        }
        selectPersonaSelection(at: index)
    }

    func confirmOverlayPickerSelection() {
        if isHistoryPickerPresented {
            confirmHistorySelection()
            return
        }
        confirmPersonaSelection()
    }

    func dismissOverlayPicker() {
        if isHistoryPickerPresented {
            dismissHistoryPicker()
            return
        }
        dismissPersonaPicker()
    }

    func personaPickerTitle(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            L("overlay.personaPicker.switchTitle")
        case .switchApplication:
            L("overlay.personaPicker.switchApplicationTitle")
        case .applySelection:
            L("overlay.personaPicker.applyTitle")
        }
    }

    func personaPickerInstructions(for mode: PersonaPickerMode) -> String {
        switch mode {
        case .switchDefault:
            L("overlay.personaPicker.switchInstructions")
        case .switchApplication:
            L("overlay.personaPicker.switchApplicationInstructions")
        case .applySelection:
            L("overlay.personaPicker.applyInstructions")
        }
    }

    func personaPickerIcon(
        for mode: PersonaPickerMode,
        applicationIcon: NSImage? = nil
    ) -> OverlayController.PersonaPickerIcon {
        switch mode {
        case .switchDefault:
            .global
        case .switchApplication:
            .application(applicationIcon)
        case .applySelection:
            .none
        }
    }

    func personaPickerEntries(includeNoneOption: Bool) -> [PersonaPickerEntry] {
        var items: [PersonaPickerEntry] = []
        if includeNoneOption {
            items.append(
                PersonaPickerEntry(
                    id: nil,
                    title: L("persona.none.title"),
                    subtitle: L("persona.none.subtitle")
                )
            )
        }
        items.append(
            contentsOf: settingsStore.personas.map {
                PersonaPickerEntry(
                    id: $0.id,
                    title: $0.name,
                    subtitle: settingsStore.resolvedPersonaPrompt(for: $0)
                )
            }
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
        soundEffectPlayer.playAsync(.tip)
        dismissPersonaPicker(immediate: true)

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
        case let .switchApplication(binding):
            settingsStore.updatePersonaAppBindingPersona(id: binding.id, personaID: selected.id)
            if selected.id != nil {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L(
                        "workflow.persona.applicationSwitched",
                        selected.title
                    ))
                }
            } else {
                Task { @MainActor in
                    self.overlayController.showNotice(message: L("workflow.persona.applicationSwitchedOff"))
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

    func dismissPersonaPicker(closeOverlay: Bool = true, immediate: Bool = false) {
        guard isPersonaPickerPresented else { return }
        isPersonaPickerPresented = false
        personaPickerItems = []
        personaPickerSelectedIndex = 0
        personaPickerMode = .switchDefault
        guard closeOverlay else { return }
        if immediate {
            overlayController.dismissImmediately()
            return
        }
        Task { @MainActor in
            self.overlayController.dismiss(after: 0.05)
        }
    }

    // swiftlint:disable:next function_body_length
    func applyPersonaToSelection(_ context: PersonaSelectionContext, persona: PersonaProfile) {
        let personaPrompt = settingsStore.resolvedPersonaPrompt(for: persona)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personaPrompt.isEmpty else { return }

        cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        let sessionID = beginProcessingSession()
        let fallbackWaitSeconds = settingsStore.voiceProcessingTimeout.seconds
        startProcessingWatchdog(sessionID: sessionID)

        var record = HistoryRecord(
            date: Date(),
            mode: .editSelection,
            personaPrompt: personaPrompt,
            selectionOriginalText: context.selectedText,
            recordingStatus: .skipped,
            transcriptionStatus: .skipped,
            processingStatus: .running,
            applyStatus: .pending
        )
        saveHistoryRecord(record)
        activeProcessingRecordID = record.id

        Task { @MainActor in
            guard self.processingSessionID == sessionID else { return }
            self.appState.setStatus(.processing)
            self.overlayController.showLLMProcessing(timeout: fallbackWaitSeconds)
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
                        personaID: persona.id,
                        appSystemContext: AppSystemContext(snapshot: context.snapshot)
                    ),
                    sessionID: sessionID,
                    showsStreamingPreview: WorkflowOverlayPresentationPolicy
                        .shouldShowLLMStreamingPreviewForPersonaSelectionApplication()
                )
                try ensureProcessingIsActive(sessionID)

                var pipelineTiming = record.pipelineTiming ?? HistoryPipelineTiming()
                pipelineTiming.llmProcessingStartedAt = pipelineTiming.llmProcessingStartedAt ?? record.date
                pipelineTiming.llmFirstOutputAt = rewriteResult.firstOutputAt
                pipelineTiming.llmProcessingCompletedAt = rewriteResult.completedAt
                pipelineTiming.llmRequestAttempts = rewriteResult.requestAttempts
                record.pipelineTiming = pipelineTiming

                let processedText = await outputPostProcessor.process(rewriteResult.text)
                record.selectionEditedText = processedText
                record.postProcessedText = processedText
                record.processingStatus = .succeeded
                record.applyStatus = .running
                saveHistoryRecord(record)
                try ensureProcessingIsActive(sessionID)
                let outcome: ApplyOutcome
                if shouldShowResultDialog {
                    try await MainActor.run {
                        try self.ensureProcessingIsActive(sessionID)
                        self.lastDialogResultText = processedText
                        self.overlayController.showResultDialog(
                            title: L("workflow.result.copyTitle"),
                            message: processedText
                        )
                    }
                    outcome = .presentedInDialog
                } else {
                    let applyResult = await applyText(
                        processedText,
                        replace: true,
                        fallbackTitle: L("workflow.result.copyTitle"),
                        targetSnapshot: context.snapshot,
                        expectedSessionID: sessionID
                    )
                    outcome = applyResult.0
                }

                try ensureProcessingIsActive(sessionID)
                record.selectionEditedText = processedText
                record.applyStatus = outcome.historyStatus
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

                if let billingError = TypefluxCloudBillingError.fromError(error) {
                    let shouldPresentBilling = await MainActor.run {
                        defer {
                            self.processingTask = nil
                            self.activeProcessingRecordID = nil
                        }
                        if self.processingSessionID == sessionID {
                            let subscription = AuthState.shared.subscription
                            self.appState.setStatus(.failed(message: billingError.title(
                                hasPaidSubscription: subscription.hasPaidSubscription,
                                billingEnabled: subscription.billingEnabled
                            )))
                            return true
                        }
                        return false
                    }
                    if shouldPresentBilling {
                        await presentCloudBillingError(billingError)
                    }
                    cancelProcessingWatchdog()
                    return
                }

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

            cancelProcessingWatchdog()
        }
    }
}
