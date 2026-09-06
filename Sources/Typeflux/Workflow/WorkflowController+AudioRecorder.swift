import AVFoundation
import Foundation

extension WorkflowController {
    @MainActor
    func presentReadyRecording() {
        guard isRecording, isAudioRecorderStarted,
              recordingAudioReadiness?.isReady == true else { return }
        RecordingStartupLatencyTrace.shared.mark("workflow.recording_ready", logSummary: true)
        appState.setStatus(.recording)
        let hint = currentRecordingHintPresentation()
        if recordingMode == .locked {
            overlayController.showLockedRecording(hintText: hint.text, autoHideHintAfter: hint.autoHideAfter)
        } else {
            overlayController.show(hintText: hint.text, autoHideHintAfter: hint.autoHideAfter)
        }
    }

    static func audioStartFailureMessage(for error: Error) -> String {
        L(audioStartFailureLocalizationKey(for: error))
    }

    static func audioStartFailureLocalizationKey(for error: Error) -> String {
        if let recorderError = error as? AVFoundationAudioRecorder.RecorderError {
            switch recorderError {
            case .inputDeviceUnavailable:
                return "workflow.audioStart.noMicrophone"
            case .inputStartupTimedOut:
                return "workflow.audioStart.microphoneNotReady"
            }
        }

        if AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error) {
            return "workflow.audioStart.microphoneNotReady"
        }
        return "workflow.audioStart.genericFailure"
    }

    func startAudioRecorderWithStartupRetry(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) async throws {
        var attempt = 1
        while true {
            do {
                try await audioRecorder.startInBackground(levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
                return
            } catch {
                let maxAttemptCount = Self.audioStartupMaxAttemptCount(for: error)
                guard
                    AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error),
                    isRecording,
                    attempt < maxAttemptCount
                else {
                    throw error
                }

                NetworkDebugLogger.logMessage(
                    """
                    [Audio Recorder] Microphone input is reconfiguring; retrying with a fresh audio engine.
                    attempt: \(attempt)
                    maxAttempts: \(maxAttemptCount)
                    retryDelayMilliseconds: 250
                    """
                )
                await sleep(Self.audioStartupRetryDelay)
                guard isRecording else {
                    throw error
                }
                attempt += 1
            }
        }
    }

    static func audioStartupMaxAttemptCount(for error: Error) -> Int {
        if let recorderError = error as? AVFoundationAudioRecorder.RecorderError,
           recorderError == .inputStartupTimedOut
        {
            return audioStartupMaxAttemptCount
        }

        return AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error)
            ? audioReconfigurationStartupMaxAttemptCount
            : audioStartupMaxAttemptCount
    }
}
