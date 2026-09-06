import AVFoundation
import Foundation

struct AudioRecorderStartupTiming: Sendable, Equatable {
    let audioEngineStartedAt: Date?
    let firstAudioBufferAt: Date?
}

struct AudioFile: Sendable {
    let fileURL: URL
    let duration: TimeInterval
    let startupTiming: AudioRecorderStartupTiming?

    init(
        fileURL: URL,
        duration: TimeInterval,
        startupTiming: AudioRecorderStartupTiming? = nil
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.startupTiming = startupTiming
    }
}

protocol AudioRecorder {
    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws
    func stop() throws -> AudioFile
}

extension AudioRecorder {
    /// Hardware start may block inside a driver. Keep it off the workflow/UI executor.
    func startInBackground(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AudioRecorderStartupQueue.queue.async {
                do {
                    try self.start(levelHandler: levelHandler, audioBufferHandler: audioBufferHandler)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start(levelHandler: @escaping (Float) -> Void) throws {
        try start(levelHandler: levelHandler, audioBufferHandler: nil)
    }
}

private enum AudioRecorderStartupQueue {
    static let queue = DispatchQueue(label: "typeflux.audio.startup", qos: .userInitiated)
}
