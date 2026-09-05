extension STTRouter {
    func prepareForRecording() async {
        switch settingsStore.sttProvider {
        case .doubaoRealtime:
            await (doubaoRealtime as? RecordingPrewarmingTranscriber)?.prepareForRecording()
        case .localModel:
            await (localModel as? RecordingPrewarmingTranscriber)?.prepareForRecording()
        case .typefluxOfficial:
            await (typefluxOfficial as? RecordingPrewarmingTranscriber)?.prepareForRecording()
        default:
            break
        }
    }

    func cancelPreparedRecording() async {
        switch settingsStore.sttProvider {
        case .doubaoRealtime:
            await (doubaoRealtime as? RecordingPrewarmingTranscriber)?.cancelPreparedRecording()
        case .localModel:
            await (localModel as? RecordingPrewarmingTranscriber)?.cancelPreparedRecording()
        case .typefluxOfficial:
            await (typefluxOfficial as? RecordingPrewarmingTranscriber)?.cancelPreparedRecording()
        default:
            break
        }
    }

    func makeRealtimeTranscriptionSession(
        scenario: TypefluxCloudScenario = .voiceInput,
        optimize: Bool = true,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void
    ) async -> (any RealtimeTranscriptionSession)? {
        switch settingsStore.sttProvider {
        case .aliCloud:
            await makeRealtimeTranscriptionSession(
                provider: aliCloud,
                scenario: scenario,
                onUpdate: onUpdate,
                failureContext: "Alibaba Cloud realtime session setup failed"
            )
        case .doubaoRealtime:
            await makeRealtimeTranscriptionSession(
                provider: doubaoRealtime,
                scenario: scenario,
                onUpdate: onUpdate,
                failureContext: "Doubao realtime session setup failed"
            )
        case .googleCloud:
            await makeRealtimeTranscriptionSession(
                provider: googleCloud,
                scenario: scenario,
                onUpdate: onUpdate,
                failureContext: "Google Cloud realtime session setup failed"
            )
        case .soniox:
            await makeRealtimeTranscriptionSession(
                provider: soniox,
                scenario: scenario,
                onUpdate: onUpdate,
                failureContext: "Soniox realtime session setup failed"
            )
        case .typefluxOfficial:
            await makeRealtimeTranscriptionSession(
                provider: typefluxOfficial,
                scenario: scenario,
                optimize: optimize,
                onUpdate: onUpdate,
                failureContext: "Typeflux Cloud realtime session setup failed"
            )
        default:
            nil
        }
    }

    private func makeRealtimeTranscriptionSession(
        provider: Transcriber,
        scenario: TypefluxCloudScenario,
        optimize: Bool = true,
        onUpdate: @escaping @Sendable (TranscriptionSnapshot) async -> Void,
        failureContext: String
    ) async -> (any RealtimeTranscriptionSession)? {
        guard let factory = provider as? RealtimeTranscriptionSessionFactory else {
            return nil
        }
        do {
            let diagnostics = RealtimeTranscriptionDiagnostics()
            let observedUpdate: @Sendable (TranscriptionSnapshot) async -> Void = { snapshot in
                diagnostics.markResult(isFinal: snapshot.isFinal)
                await onUpdate(snapshot)
            }
            let session: any RealtimeTranscriptionSession
            let appliedOptimize: Bool?
            if let optimizeAware = factory as? any OptimizeAwareRealtimeSessionFactory {
                session = try await optimizeAware.makeRealtimeTranscriptionSession(
                    scenario: scenario,
                    optimize: optimize,
                    onUpdate: observedUpdate
                )
                appliedOptimize = optimize
            } else {
                session = try await factory.makeRealtimeTranscriptionSession(
                    scenario: scenario,
                    onUpdate: observedUpdate
                )
                appliedOptimize = nil
            }
            return ObservedRealtimeTranscriptionSession(
                upstream: session,
                diagnostics: diagnostics,
                asrOptimize: appliedOptimize
            )
        } catch {
            NetworkDebugLogger.logError(context: failureContext, error: error)
            return nil
        }
    }
}
