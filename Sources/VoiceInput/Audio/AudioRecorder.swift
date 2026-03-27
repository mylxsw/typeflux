import AVFoundation
import Foundation

struct AudioFile {
    let fileURL: URL
    let duration: TimeInterval
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
