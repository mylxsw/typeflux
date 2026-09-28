import AppKit
import Foundation

/// Uses the application's recorder and configured STT router, with native editor
/// delivery instead of Accessibility/clipboard injection and a second overlay.
@MainActor
final class WorkflowComposerRecording: AskVoiceRecording {
    private weak var workflow: WorkflowController?
    private var started = false
    private var ownsRecorder = false
    private let isAppBundle: () -> Bool
    init(_ workflow: WorkflowController, isAppBundle: @escaping () -> Bool = { PrivacyGuard.isRunningInAppBundle }) {
        self.workflow = workflow; self.isAppBundle = isAppBundle
    }

    func start() async throws {
        guard let workflow, !workflow.isRecording, !workflow.isAudioRecorderStarting,
              !workflow.isAudioRecorderStarted else { throw CancellationError() }
        guard isAppBundle() else {
            throw MessageError(message: L("workflow.devApp.requiredMessage"))
        }
        if workflow.showSelectedLocalModelDownloadAlertIfNeeded() { throw CancellationError() }
        workflow.cancelCurrentProcessing(resetUI: false, reason: L("workflow.cancel.newRecording"))
        ownsRecorder = true
        workflow.isRecording = true
        workflow.isAudioRecorderStarting = true
        defer { workflow.isAudioRecorderStarting = false }
        do {
            try await workflow.audioRecorder.startInBackground(levelHandler: { _ in }, audioBufferHandler: nil)
            started = true
            workflow.isAudioRecorderStarted = true
            workflow.appState.setStatus(.recording)
        } catch {
            workflow.isRecording = false
            throw error
        }
    }

    func transcribe() async throws -> String {
        guard let workflow, started else { throw CancellationError() }
        // The same tail capture as normal dictation preserves final consonants.
        try await Task.sleep(for: WorkflowController.recordingTailCaptureDuration)
        let file = try workflow.audioRecorder.stop()
        started = false
        workflow.isRecording = false; workflow.isAudioRecorderStarted = false
        defer {
            try? FileManager.default.removeItem(at: file.fileURL)
            workflow.appState.setStatus(.idle)
            ownsRecorder = false
        }
        guard file.duration >= WorkflowController.minimumRecordingDuration else {
            throw MessageError(message: L("workflow.recording.tooShort"))
        }
        workflow.appState.setStatus(.processing)
        let text = try await workflow.sttRouter.transcribe(audioFile: file)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageError(message: L("workflow.transcription.noSpeech")) }
        return trimmed
    }

    func cancel() async {
        guard let workflow, ownsRecorder else { return }
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
        case press(intent: RecordingIntent, locked: Bool), release, stop, cancel, activationTap
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
            case .release: voice.releaseHotkey()
            case .cancel: voice.cancel()
            case .activationTap: break
            }
            return true
        }
        guard case let .press(intent, locked) = action, intent == .dictation,
              !isRecording, !isAudioRecorderStarting, !isAudioRecorderStarted,
              let editor = NSApp.keyWindow?.firstResponder as? AskComposerTextView.Editor else { return false }
        return voice.begin(in: editor, locked: locked)
    }
}
