import AVFoundation
import Foundation

final class AVFoundationAudioRecorder: AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var startedAt: Date?
    private var levelHandler: ((Float) -> Void)?
    private var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var isRecording = false

    func start(
        levelHandler: @escaping (Float) -> Void,
        audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    ) throws {
        stopInternal()

        self.levelHandler = levelHandler
        self.audioBufferHandler = audioBufferHandler

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-input", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        audioFile = try AVAudioFile(forWriting: url, settings: outputSettings)
        startedAt = Date()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() throws -> AudioFile {
        guard isRecording, let audioFile else {
            throw NSError(domain: "AudioRecorder", code: 1)
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let duration = Date().timeIntervalSince(startedAt ?? Date())
        let fileURL = audioFile.url

        self.audioFile = nil
        self.startedAt = nil
        self.levelHandler = nil
        self.audioBufferHandler = nil
        self.isRecording = false

        return AudioFile(fileURL: fileURL, duration: duration)
    }

    private func stopInternal() {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioFile = nil
        startedAt = nil
        levelHandler = nil
        audioBufferHandler = nil
        isRecording = false
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        autoreleasepool {
            do {
                let monoBuffer = try makeMonoPCMBuffer(from: buffer)
                try audioFile?.write(from: monoBuffer)
                levelHandler?(normalizePower(rmsPower(for: monoBuffer)))
                if let previewBuffer = clone(buffer: monoBuffer) {
                    audioBufferHandler?(previewBuffer)
                }
            } catch {
                NetworkDebugLogger.logError(context: "Audio buffer handling failed", error: error)
            }
        }
    }

    private func makeMonoPCMBuffer(from buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create mono audio format."]
            )
        }

        if buffer.format.channelCount == 1, buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let clone = clone(buffer: buffer, format: monoFormat) else {
                throw NSError(
                    domain: "AudioRecorder",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to clone mono audio buffer."]
                )
            }
            return clone
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: monoFormat) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter."]
            )
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: monoFormat,
            frameCapacity: buffer.frameCapacity
        ) else {
            throw NSError(
                domain: "AudioRecorder",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate mono audio buffer."]
            )
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }

        guard status != .error else {
            throw NSError(
                domain: "AudioRecorder",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unable to convert input audio."]
            )
        }

        return outputBuffer
    }

    private func clone(buffer: AVAudioPCMBuffer, format: AVAudioFormat? = nil) -> AVAudioPCMBuffer? {
        let targetFormat = format ?? buffer.format
        guard let copy = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: buffer.frameCapacity) else {
            return nil
        }

        copy.frameLength = buffer.frameLength

        guard
            let source = buffer.floatChannelData,
            let destination = copy.floatChannelData
        else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(targetFormat.channelCount)
        for channel in 0..<channelCount {
            destination[channel].update(from: source[min(channel, Int(buffer.format.channelCount) - 1)], count: frameCount)
        }

        return copy
    }

    private func rmsPower(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -60 }
        let samples = channelData[0]
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -60 }

        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(count))
        guard rms > 0 else { return -60 }
        return 20 * log10(rms)
    }

    private func normalizePower(_ power: Float) -> Float {
        let minDb: Float = -60
        let clamped = max(minDb, power)
        return (clamped - minDb) / -minDb
    }
}
