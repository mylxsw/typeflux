import AVFoundation
import Foundation

/// Presentation containers must not create an audio engine or warm microphone.
/// Their editor recorder routes to the voice owner instead.
struct FeatureAudioRecorder: AudioRecorder {
    func start(levelHandler: @escaping (Float) -> Void, audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?) throws {
        throw FeatureRPC.Failure.unavailable
    }
    func stop() throws -> AudioFile { throw FeatureRPC.Failure.unavailable }
}

struct FeatureWorkflowPress: Codable, Sendable {
    let asksSelection: Bool
    let locked: Bool
    let detectedAt: Date
    let uptime: TimeInterval?
    let auxiliary: Bool
}
