import Foundation

extension WorkflowController {
    struct DictationAnalyticsContext {
        let flowID: String
        let targetAppCategory: AnalyticsTargetAppCategory
        let sttProvider: STTProvider
        var applyOutcome: ApplyOutcome?
        var injectionMethod: String?
        var audioSignalClassification: String?
        var audioDurationSeconds: String?
        var audioRMSPowerDB: String?
        var audioPeakPowerDB: String?
        var lowEnergyRetryAttempted = false
    }

    func beginDictationAnalytics(
        intent: RecordingIntent,
        mode: RecordingMode,
        targetBundleIdentifier: String?
    ) {
        let flowID = UUID().uuidString.lowercased()
        let provider = settingsStore.sttProvider
        var properties = [
            "flow_id": flowID,
            "recording_mode": mode == .locked ? "locked" : "holdToTalk",
            "intent": intent == .dictation ? "dictation" : "askSelection",
            "stt_provider": provider.rawValue,
            "streaming_preview": "\(shouldUseLiveTranscriptionPreview())"
        ]
        if provider == .localModel {
            properties["local_model"] = settingsStore.localSTTModel.rawValue
        }

        analyticsLock.withLock {
            pendingDictationAnalyticsContext = DictationAnalyticsContext(
                flowID: flowID,
                targetAppCategory: .classify(bundleIdentifier: targetBundleIdentifier),
                sttProvider: provider
            )
        }
        analyticsReporter.report(eventName: "dictation_session_started", properties: properties)
    }

    func bindPendingDictationAnalytics(to recordID: UUID) {
        analyticsLock.withLock {
            guard let context = pendingDictationAnalyticsContext else { return }
            dictationAnalyticsContexts[recordID] = context
            pendingDictationAnalyticsContext = nil
        }
    }

    func recordPendingDictationAudioAnalysis(
        classification: AudioSignalClassification,
        analysis: AudioContentAnalysis
    ) {
        analyticsLock.withLock {
            guard var context = pendingDictationAnalyticsContext else { return }
            context.audioSignalClassification = classification.rawValue
            context.audioDurationSeconds = String(format: "%.3f", max(0, analysis.duration))
            context.audioRMSPowerDB = String(format: "%.2f", analysis.rmsPowerDB)
            context.audioPeakPowerDB = String(format: "%.2f", analysis.peakPowerDB)
            pendingDictationAnalyticsContext = context
        }
    }

    func markDictationLowEnergyRetry(recordID: UUID) {
        analyticsLock.withLock {
            guard var context = dictationAnalyticsContexts[recordID] else { return }
            context.lowEnergyRetryAttempted = true
            dictationAnalyticsContexts[recordID] = context
        }
    }

    func recordDictationApplyAnalytics(recordID: UUID, outcome: ApplyOutcome) {
        analyticsLock.withLock {
            guard var context = dictationAnalyticsContexts[recordID] else { return }
            context.applyOutcome = outcome
            context.injectionMethod = switch outcome {
            case .inserted:
                textInjector.lastInjectionMethod?.rawValue ?? TextInjectionMethod.ax.rawValue
            case .presentedInDialog:
                "clipboard_fallback"
            case .copiedToClipboard:
                "clipboard_fallback"
            }
            dictationAnalyticsContexts[recordID] = context
        }
    }

    func reportDictationTerminal(record: HistoryRecord, forcedFailure: (stage: String, kind: String)? = nil) {
        let context = analyticsLock.withLock { dictationAnalyticsContexts.removeValue(forKey: record.id) }
        guard let context else { return }

        if let failure = forcedFailure ?? dictationFailure(for: record) {
            reportDictationFailure(context: context, failure: failure)
            return
        }

        guard record.applyStatus == .succeeded else {
            let failure: (stage: String, kind: String)
            if record.transcriptionStatus != .succeeded {
                failure = ("transcription", "transcription_\(record.transcriptionStatus.rawValue)")
            } else if record.processingStatus != .succeeded {
                failure = ("processing", "processing_\(record.processingStatus.rawValue)")
            } else {
                failure = ("apply", "apply_\(record.applyStatus.rawValue)")
            }
            reportDictationFailure(context: context, failure: failure)
            return
        }
        let outcome = context.applyOutcome ?? .presentedInDialog
        let durationMilliseconds = record.pipelineStats?.endToEndMilliseconds
            ?? record.pipelineTiming?.generatedStats().endToEndMilliseconds
            ?? 0
        let applyOutcomeName = switch outcome {
        case .inserted: "inserted"
        case .presentedInDialog: "presentedInDialog"
        case .copiedToClipboard: "copiedToClipboard"
        }
        var properties = [
            "flow_id": context.flowID,
            "audio_seconds": String(format: "%.3f", max(0, record.recordingDurationSeconds ?? 0)),
            "output_chars": "\(record.finalText?.count ?? 0)",
            "pipeline_duration_ms": "\(max(0, durationMilliseconds))",
            "apply_outcome": applyOutcomeName,
            "injection_method": context.injectionMethod ?? "clipboard_fallback",
            "target_app_category": context.targetAppCategory.rawValue
        ]
        appendAudioAnalysisProperties(context: context, to: &properties)
        analyticsReporter.report(
            eventName: "dictation_session_completed",
            properties: properties
        )
    }

    func reportPendingDictationFailure(stage: String, kind: String) {
        let context = analyticsLock.withLock { () -> DictationAnalyticsContext? in
            defer { pendingDictationAnalyticsContext = nil }
            return pendingDictationAnalyticsContext
        }
        guard let context else { return }
        reportDictationFailure(context: context, failure: (stage, kind))
    }

    func discardPendingDictationAnalytics() {
        analyticsLock.withLock { pendingDictationAnalyticsContext = nil }
    }

    func discardDictationAnalytics(recordID: UUID) {
        _ = analyticsLock.withLock { dictationAnalyticsContexts.removeValue(forKey: recordID) }
    }

    private func dictationFailure(for record: HistoryRecord) -> (stage: String, kind: String)? {
        if record.recordingStatus == .failed { return ("recording", "recording_failed") }
        if record.transcriptionStatus == .failed { return ("transcription", "transcription_failed") }
        if record.processingStatus == .failed { return ("processing", "processing_failed") }
        if record.applyStatus == .failed { return ("apply", "apply_failed") }
        return nil
    }

    private func reportDictationFailure(
        context: DictationAnalyticsContext,
        failure: (stage: String, kind: String)
    ) {
        var properties = [
            "flow_id": context.flowID,
            "stage": failure.stage,
            "stt_provider": context.sttProvider.rawValue,
            "error_kind": failure.kind
        ]
        appendAudioAnalysisProperties(context: context, to: &properties)
        analyticsReporter.report(
            eventName: "dictation_session_failed",
            properties: properties
        )
    }

    private func appendAudioAnalysisProperties(
        context: DictationAnalyticsContext,
        to properties: inout [String: String]
    ) {
        properties["audio_signal"] = context.audioSignalClassification ?? "unknown"
        properties["audio_duration_seconds"] = context.audioDurationSeconds ?? "unknown"
        properties["audio_rms_db"] = context.audioRMSPowerDB ?? "unknown"
        properties["audio_peak_db"] = context.audioPeakPowerDB ?? "unknown"
        properties["low_energy_retry"] = context.lowEnergyRetryAttempted ? "true" : "false"
    }
}
