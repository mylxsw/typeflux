import AppKit
import Foundation

/// Uses the application's recorder, STT and persona rewrite, with native editor
/// delivery instead of Accessibility/clipboard injection and a second overlay.
@MainActor
final class WorkflowComposerRecording: AskVoiceRecording {
    private weak var workflow: WorkflowController?
    private var started = false
    private var ownsRecorder = false
    private var prepared = false
    private(set) var audioStartedAt: TimeInterval?
    private let isAppBundle: () -> Bool
    private var onLevel: (@MainActor (Float) -> Void)?
    private var onTranscript: (@MainActor (String, Bool) -> Void)?
    /// Holds the audio captured before the realtime recogniser is ready.
    private var audioRelay: RecordingStartupAudioBufferRelay?
    /// A realtime recogniser, when the configured service has one, shows the
    /// words while speaking; its result then replaces the pass over the file.
    private var realtime: (any RealtimeTranscriptionSession)?
    private var realtimePump: RealtimeAudioBufferPump?
    init(_ workflow: WorkflowController, isAppBundle: @escaping () -> Bool = { PrivacyGuard.isRunningInAppBundle }) {
        self.workflow = workflow; self.isAppBundle = isAppBundle
    }

    func handleHotkey(_ event: AskVoiceHotkeyEvent) {
        guard let workflow else { return }
        switch event {
        case let .prepare(auxiliary, locked):
            prepareRecording(auxiliary: auxiliary, locked: locked)
        case let .release(uptime):
            guard prepared else { return }
            workflow.extendRecordingGestureDecision(releasedAt: uptime)
        case .lock:
            guard prepared else { return }
            workflow.recordingMode = .locked
        case .promote:
            promoteToAuxiliary()
        case .finish, .cancel:
            guard prepared else { return }
            workflow.hotkeyService.settleActivationGesture()
            workflow.recordingGestureDecision?.resolve()
        }
    }

    private func promoteToAuxiliary() {
        guard let workflow else { return }
        guard prepared, let decision = workflow.recordingGestureDecision else { return }
        workflow.recordingUsesAuxiliary = true
        workflow.recordingPersonaSnapshot = nil
        if workflow.settingsStore.auxiliaryHotkey?.pressCount == 2 { workflow.recordingMode = .locked }
        decision.resolve()
    }

    private func prepareRecording(auxiliary: Bool, locked: Bool) {
        guard let workflow else { return }
        guard !workflow.isRecording, !workflow.isAudioRecorderStarting,
              !workflow.isAudioRecorderStarted else { return }
        prepared = true
        audioStartedAt = nil
        workflow.recordingUsesAuxiliary = auxiliary
        workflow.recordingAllowsQuickInput = true
        workflow.recordingPersonaSnapshot = nil
        workflow.recordingIntent = .dictation
        workflow.recordingMode = locked ? .locked : .holdToTalk
        workflow.prepareRecordingGesture(intent: .dictation, startLocked: locked, auxiliary: auxiliary)
    }

    private func settlePersona() {
        guard let workflow else { return }
        workflow.hotkeyService.settleActivationGesture()
        workflow.recordingGestureDecision = nil
        workflow.snapshotRecordingPersona(
            appName: ProcessInfo.processInfo.processName,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    func observe(level: @escaping @MainActor (Float) -> Void,
                 transcript: @escaping @MainActor (String, Bool) -> Void) {
        onLevel = level
        onTranscript = transcript
    }

    func start() async throws {
        guard let workflow, !workflow.isRecording, !workflow.isAudioRecorderStarting,
              !workflow.isAudioRecorderStarted else { throw CancellationError() }
        guard isAppBundle() else {
            throw MessageError(message: L("workflow.devApp.requiredMessage"))
        }
        if workflow.showSelectedLocalModelDownloadAlertIfNeeded() { throw CancellationError() }
        if !prepared { handleHotkey(.prepare(auxiliary: false, locked: true)) }
        workflow.cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        ownsRecorder = true
        workflow.isRecording = true
        workflow.isAudioRecorderStarting = true
        defer { workflow.isAudioRecorderStarting = false }
        // Audio waits here until the realtime recogniser is ready, then streams to it.
        let relay = RecordingStartupAudioBufferRelay(maximumBufferedDuration: Self.maximumRelayedAudio)
        audioRelay = relay
        let level = onLevel
        do {
            try await workflow.audioRecorder.startInBackground(levelHandler: { value in
                guard let level else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { level(value) } }
            }, audioBufferHandler: { buffer in
                guard buffer.frameLength > 0 else { return }
                relay.append(buffer)
            })
            started = true
            workflow.isAudioRecorderStarted = true
            audioStartedAt = workflow.monotonicNow()
            workflow.isAudioRecorderStarting = false
            workflow.appState.setStatus(.recording)
            if let decision = workflow.recordingGestureDecision {
                await decision.wait()
            }
            try Task.checkCancellation()
            settlePersona()
            await startRealtime(relay: relay)
        } catch {
            relay.cancel()
            workflow.isRecording = false
            throw error
        }
    }

    /// Audio kept for a realtime recogniser that is still connecting.
    static let maximumRelayedAudio: TimeInterval = 30

    /// The persona prompt the transcript is rewritten with; quick input skips it.
    private var personaPrompt: String? {
        guard let workflow else { return nil }
        let quickInput = workflow.shouldUseQuickInput(recordingMode: workflow.recordingMode, recordingIntent: .dictation)
        return quickInput ? nil : workflow.recordingPersonaSnapshot?.prompt
    }

    private func startRealtime(relay: RecordingStartupAudioBufferRelay) async {
        guard let workflow else { relay.cancel(); return }
        let transcript = onTranscript
        let session = await workflow.sttRouter.makeRealtimeTranscriptionSession(
            scenario: .voiceInput, optimize: !WorkflowController.hasRewritePersona(personaPrompt)
        ) { snapshot in
            guard let transcript else { return }
            await MainActor.run { transcript(snapshot.text, snapshot.isFinal) }
        }
        guard let session else { relay.cancel(); return }
        await session.start()
        // Cancelled or stopped while connecting: nothing will read the session.
        guard started, audioRelay === relay, !Task.isCancelled else {
            relay.cancel()
            await session.cancel()
            return
        }
        let pump = RealtimeAudioBufferPump(session: session)
        realtime = session
        realtimePump = pump
        relay.activate { pump.append($0) }
    }

    /// Takes the realtime result when there is one, else transcribes the file.
    /// A realtime failure falls back to the file, as dictation does.
    private func recognize(file: AudioFile, session: (any RealtimeTranscriptionSession)?,
                           pump: RealtimeAudioBufferPump?, optimize: Bool) async throws -> String {
        guard let workflow else { throw CancellationError() }
        let router = workflow.sttRouter
        guard let session else {
            return try await router.transcribeStream(audioFile: file, optimize: optimize) { _ in }
        }
        await pump?.finishInput()
        do {
            if workflow.settingsStore.sttProvider == .typefluxOfficial, router.usesTypefluxOfficialCloudLocalRace {
                return try await router.transcribeWithTypefluxOfficialCloudPriority(audioFile: file, onUpdate: { _ in }) {
                    try await session.finish()
                }
            }
            return try await session.finish()
        } catch is CancellationError {
            await session.cancel()
            throw CancellationError()
        } catch {
            NetworkDebugLogger.logError(context: "Composer realtime STT failed; falling back to recorded audio",
                                        error: error)
            return try await router.transcribeStream(audioFile: file, optimize: optimize) { _ in }
        }
    }

    /// Hands over the realtime recogniser. Finishing keeps the relay delivering
    /// the last buffers still on their way from the stopped recorder; the
    /// pump's end of input closes the stream. Cancelling drops them.
    private func releaseRealtime(cancelling: Bool) -> (session: (any RealtimeTranscriptionSession)?,
                                                       pump: RealtimeAudioBufferPump?) {
        if cancelling { audioRelay?.cancel() }
        audioRelay = nil
        defer { realtime = nil; realtimePump = nil }
        return (realtime, realtimePump)
    }

    func transcribe() async throws -> String {
        guard let workflow, started else { throw CancellationError() }
        handleHotkey(.finish)
        settlePersona()
        let useQuickInput = workflow.shouldUseQuickInput(
            recordingMode: workflow.recordingMode, recordingIntent: .dictation
        )
        let persona = workflow.recordingPersonaSnapshot
        // The same tail capture as normal dictation preserves final consonants.
        try await Task.sleep(for: WorkflowController.recordingTailCaptureDuration)
        let file: AudioFile
        do {
            file = try workflow.audioRecorder.stop()
        } catch {
            let pending = releaseRealtime(cancelling: true)
            pending.pump?.cancel()
            await pending.session?.cancel()
            throw error
        }
        let pending = releaseRealtime(cancelling: false)
        started = false
        workflow.isRecording = false; workflow.isAudioRecorderStarted = false
        defer {
            try? FileManager.default.removeItem(at: file.fileURL)
            workflow.appState.setStatus(.idle)
            ownsRecorder = false
            prepared = false
        }
        guard file.duration >= WorkflowController.minimumRecordingDuration else {
            pending.pump?.cancel()
            await pending.session?.cancel()
            throw MessageError(message: L("workflow.recording.tooShort"))
        }
        workflow.appState.setStatus(.processing)
        let personaContext = TranscriptionPersonaContext(prompt: useQuickInput ? nil : persona?.prompt)
        let text = try await TranscriptionPersonaContext.$current.withValue(personaContext) {
            try await recognize(file: file, session: pending.session, pump: pending.pump,
                                optimize: !WorkflowController.hasRewritePersona(personaContext.prompt))
        }
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageError(message: L("workflow.transcription.noSpeech")) }
        guard WorkflowController.hasRewritePersona(personaContext.prompt), !personaContext.wasApplied else {
            return trimmed
        }
        let result = try await workflow.generateRewrite(
            request: LLMRewriteRequest(
                mode: .rewriteTranscript, sourceText: trimmed, spokenInstruction: nil,
                personaPrompt: personaContext.prompt, personaID: persona?.persona?.id,
                vocabularyTerms: VocabularyStore.activeTerms()
            ),
            sessionID: workflow.processingSessionID,
            showsStreamingPreview: false,
            presentsConfigurationFailure: false,
            timeoutBudget: workflow.llmRewriteTimeoutBudget(for: trimmed)
        )
        try Task.checkCancellation()
        return result.text
    }

    func cancel() async {
        let pending = releaseRealtime(cancelling: true)
        pending.pump?.cancel()
        await pending.session?.cancel()
        guard let workflow else { return }
        if prepared {
            workflow.recordingGestureDecision?.resolve()
            workflow.recordingGestureDecision = nil
            workflow.recordingPersonaSnapshot = nil
            prepared = false
        }
        guard ownsRecorder else { return }
        ownsRecorder = false
        if started, let file = try? workflow.audioRecorder.stop() {
            try? FileManager.default.removeItem(at: file.fileURL)
        }
        started = false
        workflow.isRecording = false; workflow.isAudioRecorderStarted = false
        workflow.appState.setStatus(.idle)
    }

    private struct MessageError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

extension WorkflowController {
    enum ComposerVoiceAction {
        case press(intent: RecordingIntent, locked: Bool, auxiliary: Bool = false, uptime: TimeInterval? = nil)
        case release(TimeInterval), stop, cancel, activationTap(TimeInterval), promote(TimeInterval)
    }

    /// Legacy workflow entry points also run from recorder tasks. Serialize the
    /// native editor boundary on the main queue before falling through to them.
    func routeComposerVoice(_ action: ComposerVoiceAction) -> Bool {
        guard composerVoiceInput != nil else { return false }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { routeComposerVoiceOnMain(action) }
        }
        return DispatchQueue.main.sync { routeComposerVoiceOnMain(action) }
    }

    @MainActor
    private func routeComposerVoiceOnMain(_ action: ComposerVoiceAction) -> Bool {
        guard let voice = composerVoiceInput else { return false }
        if voice.isOccupied {
            switch action {
            case .press, .stop: voice.stop()
            case let .release(uptime), let .activationTap(uptime): voice.releaseHotkey(at: uptime)
            case let .promote(uptime):
                if recordingGestureDecision != nil {
                    voice.promoteHotkey(at: uptime, locked: settingsStore.auxiliaryHotkey?.pressCount == 2)
                }
            case .cancel: voice.cancel()
            }
            return true
        }
        guard case let .press(intent, locked, auxiliary, uptime) = action, intent == .dictation,
              !isRecording, !isAudioRecorderStarting, !isAudioRecorderStarted,
              let editor = NSApp.keyWindow?.firstResponder as? AskComposerTextView.Editor else { return false }
        return voice.begin(in: editor, locked: locked, auxiliary: auxiliary, hotkeyUptime: uptime)
    }
}
