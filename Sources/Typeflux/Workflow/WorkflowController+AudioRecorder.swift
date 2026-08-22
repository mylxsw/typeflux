import AVFoundation
import Foundation

extension WorkflowController {
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
        for attempt in 1 ... Self.audioStartupMaxAttemptCount {
            do {
                try audioRecorder.start(levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
                return
            } catch {
                guard
                    AVFoundationAudioRecorder.isRecoverableInputReconfigurationError(error),
                    isRecording,
                    attempt < Self.audioStartupMaxAttemptCount
                else {
                    throw error
                }

                NetworkDebugLogger.logMessage(
                    """
                    [Audio Recorder] Microphone input is reconfiguring; retrying with a fresh audio engine.
                    attempt: \(attempt)
                    maxAttempts: \(Self.audioStartupMaxAttemptCount)
                    retryDelayMilliseconds: 250
                    """
                )
                await sleep(Self.audioStartupRetryDelay)
                guard isRecording else {
                    throw error
                }
            }
        }
    }
}
