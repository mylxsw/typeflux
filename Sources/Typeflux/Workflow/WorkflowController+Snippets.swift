import Foundation

extension WorkflowController {
    /// Exact snippet insertion bypasses rewriting, OpenCC and punctuation optimization.
    func processSnippetCommand(alias: String, sessionID: UUID, record: inout HistoryRecord,
                               pipelineTiming: inout HistoryPipelineTiming) async throws {
        try ensureProcessingIsActive(sessionID)
        let item = clipboardHistoryStore?.items(limit: Int(Int32.max)).first {
            guard let snippet = $0.snippet, !snippet.alias.isEmpty else { return false }
            return ClipboardSnippet.normalizedAlias(snippet.alias) == alias
        }
        record.mode = .dictation
        record.processingStatus = .skipped
        guard let text = item?.text else {
            record.applyStatus = .skipped
            record.applyMessage = L("clipboard.snippet.notFound")
            await MainActor.run {
                shouldPreserveLLMConfigurationNotice = true
                overlayController.showNotice(message: L("clipboard.snippet.notFound"))
                overlayController.dismiss(after: 2)
            }
            return
        }
        record.postProcessedText = text
        record.applyStatus = .running
        pipelineTiming.applyStartedAt = Date()
        record.pipelineTiming = pipelineTiming
        saveHistoryRecord(record)
        let (result, appliedAt) = await TextDeliveryTiming.measure {
            await applyText(text, replace: false, expectedSessionID: sessionID)
        }
        pipelineTiming.applyCompletedAt = appliedAt
        record.pipelineTiming = pipelineTiming
        record.applyStatus = result.0.historyStatus
        record.applyMessage = result.0.message
        recordDictationApplyAnalytics(recordID: record.id, outcome: result.0)
    }
}
