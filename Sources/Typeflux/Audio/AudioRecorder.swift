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
    func start(levelHandler: @escaping (Float) -> Void) throws {
        try start(levelHandler: levelHandler, audioBufferHandler: nil)
    }
}
