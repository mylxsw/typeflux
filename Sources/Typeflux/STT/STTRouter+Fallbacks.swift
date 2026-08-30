import Foundation

extension STTRouter {
    func handleLocalModelFailure(
        _ error: Error,
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        NetworkDebugLogger.logError(context: "Local STT failed", error: error)
        if let localResult = await transcribeWithAutoModelIfReady(audioFile: audioFile, onUpdate: onUpdate) {
            NetworkDebugLogger.logMessage("Auto local model succeeded after local STT failure")
            return localResult
        }
        if await shouldUseTypefluxCloudForUnavailableLocalModel(error: error) {
            return try await transcribeWithCloudFallbackForUnavailableLocalModel(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        }
        if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
            message: "Falling back to Apple Speech after local STT failure",
            audioFile: audioFile,
            onUpdate: onUpdate
        ) {
            return appleResult
        }
        throw error
    }

    func transcribeWithTypefluxOfficialProvider(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool = true,
        diagnosticsRecorder: ASRRaceDiagnosticsRecorder? = nil,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        guard typefluxCloudLoginFallbackLocalModel != nil else {
            do {
                return try await transcribeWithTypefluxOfficial(
                    audioFile: audioFile,
                    scenario: scenario,
                    optimize: optimize,
                    onUpdate: onUpdate
                )
            } catch {
                return try await handleTypefluxOfficialFailure(error, audioFile: audioFile, onUpdate: onUpdate)
            }
        }

        return try await transcribeWithTypefluxOfficialCloudPriority(
            audioFile: audioFile,
            onUpdate: onUpdate,
            diagnosticsRecorder: diagnosticsRecorder
        ) { [self] in
            try await transcribeWithTypefluxOfficial(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        }
    }

    func transcribeWithTypefluxOfficialCloudPriority(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        diagnosticsRecorder: ASRRaceDiagnosticsRecorder? = nil,
        cloudOperation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        guard let localTranscriber = typefluxCloudLoginFallbackLocalModel else {
            return try await cloudOperation()
        }

        let startedAt = Date()
        do {
            let result = try await CloudLocalTranscriptionRacer(
                priorityWindow: typefluxOfficialCloudPriorityWindow
            ).race(
                cloud: cloudOperation,
                local: {
                    try await localTranscriber.transcribeStream(audioFile: audioFile) { _ in }
                },
                diagnosticsRecorder: diagnosticsRecorder
            )
            if result.source == .local {
                await onUpdate(TranscriptionSnapshot(text: result.text, isFinal: true))
            }
            NetworkDebugLogger.logMessage(
                "[ASR Race] selected=\(result.source.rawValue) " +
                    "elapsed_ms=\(String(format: "%.1f", Date().timeIntervalSince(startedAt) * 1000)) " +
                    "cloud_priority_window_s=\(String(format: "%.1f", typefluxOfficialCloudPriorityWindow))"
            )
            return result.text
        } catch is CancellationError {
            throw CancellationError()
        } catch let raceError as CloudLocalTranscriptionRaceError {
            if let localError = raceError.localError {
                NetworkDebugLogger.logError(context: "Concurrent local STT failed", error: localError)
            }
            guard let cloudError = raceError.cloudError else {
                throw raceError
            }
            return try await handleTypefluxOfficialFailure(
                cloudError,
                audioFile: audioFile,
                onUpdate: onUpdate,
                skipTypefluxCloudLocalFallback: true
            )
        }
    }

    func handleIntegratedTypefluxFailure(
        _ error: Error,
        audioFile: AudioFile,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        NetworkDebugLogger.logError(context: "Typeflux Official integrated STT+LLM failed", error: error)
        if let integratedError = error as? TypefluxCloudIntegratedRewriteError {
            NetworkDebugLogger.logMessage(
                "Integrated Typeflux Cloud LLM failed after ASR completed; using transcript fallback"
            )
            return (transcript: integratedError.transcript, rewritten: nil)
        }
        if let billingError = TypefluxCloudBillingError.fromError(error) {
            if let localResult = await transcribeWithTypefluxCloudCreditFallbackModelIfAvailable(
                billingError: billingError,
                audioFile: audioFile,
                onUpdate: onASRUpdate
            ) {
                return (transcript: localResult, rewritten: nil)
            }
            throw billingError
        }
        if let fallback = await transcribeWithCloudLoginFallbackIfNeeded(
            error,
            audioFile: audioFile,
            onUpdate: onASRUpdate
        ) {
            return (transcript: fallback, rewritten: nil)
        }
        if let localResult = await transcribeWithAutoModelIfReady(audioFile: audioFile, onUpdate: onASRUpdate) {
            NetworkDebugLogger.logMessage("Auto local model succeeded after integrated Typeflux Official failure")
            return (transcript: localResult, rewritten: nil)
        }
        if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
            message: "Falling back to Apple Speech after integrated Typeflux Official failure",
            audioFile: audioFile,
            onUpdate: onASRUpdate
        ) {
            return (transcript: appleResult, rewritten: nil)
        }
        throw error
    }

    func transcribeWithAutoModelIfReady(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> String? {
        guard let transcriber = autoModelDownloadService?.makeTranscriberIfReady()
        else {
            return nil
        }
        return try? await transcriber.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
    }

    func transcribeWithConnectivityFallbackIfAvailable(
        error: Error,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> String? {
        guard ServerConnectivityFailure.matches(error),
              let fallback = typefluxCloudLoginFallbackLocalModel
        else {
            return nil
        }

        do {
            NetworkDebugLogger.logMessage(
                "Server unavailable; falling back to the default local speech model"
            )
            return try await fallback.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        } catch {
            NetworkDebugLogger.logError(context: "Default local connectivity fallback failed", error: error)
            return nil
        }
    }

    func transcribeWithAppleSpeechFallbackIfEnabled(
        message: String,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String? {
        guard settingsStore.useAppleSpeechFallback else {
            return nil
        }
        NetworkDebugLogger.logMessage(message)
        return try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
    }

    private func transcribeWithCloudFallbackForUnavailableLocalModel(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        do {
            NetworkDebugLogger.logMessage("Falling back to Typeflux Cloud while local STT model downloads")
            return try await transcribeWithTypefluxOfficial(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        } catch {
            return try await handleTypefluxCloudFallbackFailure(error, audioFile: audioFile, onUpdate: onUpdate)
        }
    }

    private func handleTypefluxCloudFallbackFailure(
        _ error: Error,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        NetworkDebugLogger.logError(context: "Typeflux Cloud fallback failed", error: error)
        if let billingError = TypefluxCloudBillingError.fromError(error) {
            if let localResult = await transcribeWithTypefluxCloudCreditFallbackModelIfAvailable(
                billingError: billingError,
                audioFile: audioFile,
                onUpdate: onUpdate
            ) {
                return localResult
            }
            throw billingError
        }
        if TypefluxCloudLoginRequiredError.fromError(error) != nil,
           let localResult = await transcribeWithTypefluxCloudLoginFallbackModelIfAvailable(
               audioFile: audioFile,
               onUpdate: onUpdate
           ) {
            return localResult
        }
        if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
            message: "Falling back to Apple Speech after Typeflux Cloud fallback failure",
            audioFile: audioFile,
            onUpdate: onUpdate
        ) {
            return appleResult
        }
        throw error
    }

    private func handleTypefluxOfficialFailure(
        _ error: Error,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        skipTypefluxCloudLocalFallback: Bool = false
    ) async throws -> String {
        NetworkDebugLogger.logError(context: "Typeflux Official STT failed", error: error)
        if let billingError = TypefluxCloudBillingError.fromError(error) {
            if !skipTypefluxCloudLocalFallback,
               let localResult = await transcribeWithTypefluxCloudCreditFallbackModelIfAvailable(
                billingError: billingError,
                audioFile: audioFile,
                onUpdate: onUpdate
            ) {
                return localResult
            }
            throw billingError
        }
        if !skipTypefluxCloudLocalFallback,
           let fallback = await transcribeWithCloudLoginFallbackIfNeeded(
            error,
            audioFile: audioFile,
            onUpdate: onUpdate
        ) {
            return fallback
        }
        if let localResult = await transcribeWithAutoModelIfReady(audioFile: audioFile, onUpdate: onUpdate) {
            NetworkDebugLogger.logMessage("Auto local model succeeded after Typeflux Official STT failure")
            return localResult
        }
        if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
            message: "Falling back to Apple Speech after Typeflux Official STT failure",
            audioFile: audioFile,
            onUpdate: onUpdate
        ) {
            return appleResult
        }
        throw error
    }

    private func transcribeWithCloudLoginFallbackIfNeeded(
        _ error: Error,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> String? {
        guard TypefluxCloudLoginRequiredError.fromError(error) != nil else {
            return nil
        }
        return await transcribeWithTypefluxCloudLoginFallbackModelIfAvailable(
            audioFile: audioFile,
            onUpdate: onUpdate
        )
    }

    private func transcribeWithTypefluxCloudLoginFallbackModelIfAvailable(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> String? {
        guard let fallback = typefluxCloudLoginFallbackLocalModel else {
            return nil
        }
        do {
            NetworkDebugLogger.logMessage("Falling back to default SenseVoice after Typeflux Cloud login failure")
            return try await fallback.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        } catch {
            NetworkDebugLogger.logError(context: "Default SenseVoice fallback failed", error: error)
            return nil
        }
    }

    private func transcribeWithTypefluxCloudCreditFallbackModelIfAvailable(
        billingError: TypefluxCloudBillingError,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> String? {
        guard billingError.reason == .quotaExceeded,
              await hasPaidTypefluxCloudSubscription()
        else {
            return nil
        }
        guard let fallback = typefluxCloudLoginFallbackLocalModel else {
            return nil
        }
        do {
            NetworkDebugLogger.logMessage(
                "Falling back to default SenseVoice after Typeflux Cloud credits were exhausted"
            )
            return try await fallback.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        } catch {
            NetworkDebugLogger.logError(context: "Default SenseVoice credit fallback failed", error: error)
            return nil
        }
    }

    private func transcribeWithTypefluxOfficial(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool = true,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        try await RequestRetry.perform(operationName: "Typeflux Official STT request") { [self] in
            if let optimizeAware = typefluxOfficial as? ASROptimizeAwareTranscriber {
                return try await optimizeAware.transcribeStream(
                    audioFile: audioFile,
                    scenario: scenario,
                    optimize: optimize,
                    onUpdate: onUpdate
                )
            }
            if let scenarioAware = typefluxOfficial as? TypefluxCloudScenarioAwareTranscriber {
                return try await scenarioAware.transcribeStream(
                    audioFile: audioFile,
                    scenario: scenario,
                    onUpdate: onUpdate
                )
            }
            return try await typefluxOfficial.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        }
    }

    private func shouldUseTypefluxCloudForUnavailableLocalModel(error: Error) async -> Bool {
        let nsError = error as NSError
        guard nsError.domain == LocalModelTranscriber.notPreparedErrorDomain,
              nsError.code == LocalModelTranscriber.notPreparedErrorCode
        else {
            return false
        }
        return await isTypefluxCloudLoggedIn()
    }
}
