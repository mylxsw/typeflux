import Foundation

private struct RemoteSTTRoute {
    let provider: Transcriber
    let operationName: String
    let failureContext: String
    let autoModelSuccessMessage: String
    let appleFallbackMessage: String
}

extension STTRouter {
    func transcribeStream(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario = .voiceInput,
        optimize: Bool = true,
        diagnosticsRecorder: ASRRaceDiagnosticsRecorder? = nil,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        switch settingsStore.sttProvider {
        case .freeModel, .whisperAPI, .aliCloud, .doubaoRealtime, .googleCloud, .soniox:
            try await transcribeWithRemoteProvider(
                route: remoteSTTRoute(for: settingsStore.sttProvider),
                audioFile: audioFile,
                onUpdate: onUpdate
            )
        case .appleSpeech:
            try await appleSpeech.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        case .localModel:
            try await transcribeWithLocalModel(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        case .multimodalLLM:
            try await transcribeWithRemoteProvider(
                route: remoteSTTRoute(for: .multimodalLLM),
                audioFile: audioFile,
                onUpdate: onUpdate
            )
        case .groq:
            try await transcribeWithGroq(audioFile: audioFile, onUpdate: onUpdate)
        case .typefluxOfficial:
            try await transcribeWithTypefluxOfficialProvider(
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                diagnosticsRecorder: diagnosticsRecorder,
                onUpdate: onUpdate
            )
        }
    }

    // Runs transcription and, if supported, an LLM persona rewrite in the same WebSocket session.
    // swiftlint:disable:next function_parameter_count
    func transcribeStreamWithLLMRewrite(
        audioFile: AudioFile,
        llmConfig: ASRLLMConfig,
        scenario: TypefluxCloudScenario,
        onASRUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        onLLMStart: @escaping @Sendable () async -> Void,
        onLLMChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> (transcript: String, rewritten: String?) {
        guard let integrated = typefluxOfficial as? TypefluxCloudLLMIntegratedTranscriber else {
            let transcript = try await transcribeStream(audioFile: audioFile, scenario: scenario, onUpdate: onASRUpdate)
            return (transcript: transcript, rewritten: nil)
        }
        do {
            return try await integrated.transcribeStreamWithLLMRewrite(
                audioFile: audioFile,
                llmConfig: llmConfig,
                scenario: scenario,
                onASRUpdate: onASRUpdate,
                onLLMStart: onLLMStart,
                onLLMChunk: onLLMChunk
            )
        } catch {
            return try await handleIntegratedTypefluxFailure(
                error,
                audioFile: audioFile,
                onASRUpdate: onASRUpdate
            )
        }
    }

    private func transcribeWithRemoteProvider(
        route: RemoteSTTRoute,
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        do {
            return try await RequestRetry.perform(
                operationName: route.operationName,
                shouldRetry: { !ServerConnectivityFailure.matches($0) }
            ) {
                try await route.provider.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
            }
        } catch {
            NetworkDebugLogger.logError(context: route.failureContext, error: error)
            if let localResult = await transcribeWithAutoModelIfReady(audioFile: audioFile, onUpdate: onUpdate) {
                NetworkDebugLogger.logMessage(route.autoModelSuccessMessage)
                return localResult
            }
            if let localResult = await transcribeWithConnectivityFallbackIfAvailable(
                error: error,
                audioFile: audioFile,
                onUpdate: onUpdate
            ) {
                NetworkDebugLogger.logMessage(
                    "Default local model succeeded after a server connectivity failure"
                )
                return localResult
            }
            if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
                message: route.appleFallbackMessage,
                audioFile: audioFile,
                onUpdate: onUpdate
            ) {
                return appleResult
            }
            throw error
        }
    }

    private func transcribeWithLocalModel(
        audioFile: AudioFile,
        scenario: TypefluxCloudScenario,
        optimize: Bool,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        do {
            return try await localModel.transcribeStream(audioFile: audioFile, onUpdate: onUpdate)
        } catch {
            return try await handleLocalModelFailure(
                error,
                audioFile: audioFile,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate
            )
        }
    }

    private func transcribeWithGroq(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        guard !settingsStore.groqSTTAPIKey.isEmpty else {
            return try await transcribeWithMissingGroqConfiguration(audioFile: audioFile, onUpdate: onUpdate)
        }
        return try await transcribeWithRemoteProvider(
            route: RemoteSTTRoute(
                provider: groq,
                operationName: "Groq STT request",
                failureContext: "Groq STT failed",
                autoModelSuccessMessage: "Auto local model succeeded after Groq STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after Groq STT failure"
            ),
            audioFile: audioFile,
            onUpdate: onUpdate
        )
    }

    private func transcribeWithMissingGroqConfiguration(
        audioFile: AudioFile,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async throws -> String {
        if let localResult = await transcribeWithAutoModelIfReady(audioFile: audioFile, onUpdate: onUpdate) {
            NetworkDebugLogger.logMessage("Auto local model used because Groq STT is not configured")
            return localResult
        }
        if let appleResult = try await transcribeWithAppleSpeechFallbackIfEnabled(
            message: "Groq STT is not configured, using Apple Speech fallback",
            audioFile: audioFile,
            onUpdate: onUpdate
        ) {
            return appleResult
        }
        throw NSError(
            domain: "STTRouter",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Groq transcription is not configured yet."]
        )
    }

    // swiftlint:disable:next function_body_length
    private func remoteSTTRoute(for provider: STTProvider) -> RemoteSTTRoute {
        switch provider {
        case .freeModel:
            return RemoteSTTRoute(
                provider: freeSTT,
                operationName: "Free STT request",
                failureContext: "Free STT failed",
                autoModelSuccessMessage: "Auto local model succeeded after free STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after free STT failure"
            )
        case .whisperAPI:
            return RemoteSTTRoute(
                provider: whisper,
                operationName: "Remote STT request",
                failureContext: "Remote STT failed",
                autoModelSuccessMessage: "Auto local model succeeded after remote STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after remote STT failure"
            )
        case .aliCloud:
            return RemoteSTTRoute(
                provider: aliCloud,
                operationName: "AliCloud STT request",
                failureContext: "Alibaba Cloud ASR failed",
                autoModelSuccessMessage: "Auto local model succeeded after Alibaba Cloud ASR failure",
                appleFallbackMessage: "Falling back to Apple Speech after Alibaba Cloud ASR failure"
            )
        case .doubaoRealtime:
            return RemoteSTTRoute(
                provider: doubaoRealtime,
                operationName: "Doubao realtime STT request",
                failureContext: "Doubao realtime ASR failed",
                autoModelSuccessMessage: "Auto local model succeeded after Doubao realtime ASR failure",
                appleFallbackMessage: "Falling back to Apple Speech after Doubao realtime ASR failure"
            )
        case .googleCloud:
            return RemoteSTTRoute(
                provider: googleCloud,
                operationName: "Google Cloud STT request",
                failureContext: "Google Cloud Speech-to-Text failed",
                autoModelSuccessMessage: "Auto local model succeeded after Google Cloud STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after Google Cloud STT failure"
            )
        case .soniox:
            return RemoteSTTRoute(
                provider: soniox,
                operationName: "Soniox STT request",
                failureContext: "Soniox ASR failed",
                autoModelSuccessMessage: "Auto local model succeeded after Soniox ASR failure",
                appleFallbackMessage: "Falling back to Apple Speech after Soniox ASR failure"
            )
        case .multimodalLLM:
            return RemoteSTTRoute(
                provider: multimodal,
                operationName: "Multimodal STT request",
                failureContext: "Multimodal STT failed",
                autoModelSuccessMessage: "Auto local model succeeded after multimodal STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after multimodal STT failure"
            )
        default:
            assertionFailure("Unexpected non-remote STT provider")
            return RemoteSTTRoute(
                provider: appleSpeech,
                operationName: "Unexpected STT request",
                failureContext: "Unexpected STT failed",
                autoModelSuccessMessage: "Auto local model succeeded after unexpected STT failure",
                appleFallbackMessage: "Falling back to Apple Speech after unexpected STT failure"
            )
        }
    }
}
