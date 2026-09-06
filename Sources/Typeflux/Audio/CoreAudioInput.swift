import AVFoundation
import CoreAudio
import Foundation
import TypefluxAudioSafety

struct CoreAudioInputPacket {
    let buffer: AVAudioPCMBuffer
    let sampleHostTime: UInt64
    let callbackHostTime: UInt64
}

/// All methods are owned by CoreAudioRecorder's serial queue. The C implementation
/// alone runs on the real-time thread and transfers samples through an atomic SPSC ring.
protocol CoreAudioInputCapturing: AnyObject {
    var format: AVAudioFormat { get }
    var deviceBufferFrames: UInt32 { get }
    var captureError: Error? { get }
    func start() throws
    func stop()
    func read() -> CoreAudioInputPacket?
}

final class CoreAudioInput: CoreAudioInputCapturing {
    private let input: OpaquePointer
    let format: AVAudioFormat
    let deviceBufferFrames: UInt32
    private let maximumFrames: UInt32

    init(deviceID: AudioDeviceID) throws {
        var status: OSStatus = noErr
        guard let input = TFHALInputCreate(deviceID, &status) else {
            throw Self.error(status)
        }
        let configuration = TFHALInputGetFormat(input)
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: configuration.sampleRate,
                channels: configuration.channels,
                interleaved: true
            )
        else {
            TFHALInputDestroy(input)
            throw AVFoundationAudioRecorder.RecorderError.inputDeviceUnavailable
        }
        self.input = input
        self.format = format
        maximumFrames = configuration.maximumFrames
        deviceBufferFrames = configuration.deviceBufferFrames
    }

    deinit { TFHALInputDestroy(input) }

    func start() throws {
        let status = TFHALInputStart(input)
        guard status == noErr else { throw Self.error(status) }
    }

    func stop() { TFHALInputStop(input) }

    var captureError: Error? {
        let status = TFHALInputGetError(input)
        if status != noErr { return Self.error(status) }
        if TFHALInputDroppedFrames(input) > 0 {
            return NSError(
                domain: "CoreAudioRecorder", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "The audio consumer could not keep up with microphone input."
                ])
        }
        return nil
    }

    func read() -> CoreAudioInputPacket? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames),
            let samples = buffer.floatChannelData?.pointee
        else { return nil }
        var packet = TFHALInputPacket()
        guard TFHALInputRead(input, samples, maximumFrames, &packet) else { return nil }
        buffer.frameLength = packet.frames
        return CoreAudioInputPacket(
            buffer: buffer, sampleHostTime: packet.sampleHostTime,
            callbackHostTime: packet.callbackHostTime)
    }

    private static func error(_ status: OSStatus) -> Error {
        NSError(
            domain: NSOSStatusErrorDomain, code: Int(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Microphone input failed (Core Audio status \(status))."
            ])
    }
}
