import AVFoundation
import Foundation

enum LowEnergyAudioPreparer {
    static let targetSampleRate: Double = 16_000
    static let paddingDuration: TimeInterval = 0.2
    static let targetPeakPowerDB: Float = -12
    static let maximumGainDB: Float = 18

    static func prepare(
        audioFile: AudioFile,
        analysis: AudioContentAnalysis
    ) throws -> AudioFile {
        let sourceFile = try AVAudioFile(forReading: audioFile.fileURL)
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-low-energy-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        do {
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
            let outputFormat = outputFile.processingFormat
            guard let converter = AVAudioConverter(
                from: sourceFile.processingFormat,
                to: outputFormat
            ) else {
                throw preparationError(code: 1, message: "Unable to create low-energy audio converter.")
            }

            let gain = linearGain(for: analysis.peakPowerDB)
            try writeSilence(to: outputFile, format: outputFormat)
            try convert(
                sourceFile: sourceFile,
                converter: converter,
                outputFile: outputFile,
                outputFormat: outputFormat,
                gain: gain
            )
            try writeSilence(to: outputFile, format: outputFormat)

            return AudioFile(
                fileURL: outputURL,
                duration: analysis.duration + (paddingDuration * 2)
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func linearGain(for peakPowerDB: Float) -> Float {
        guard peakPowerDB.isFinite, peakPowerDB < targetPeakPowerDB else { return 1 }
        let gainDB = min(maximumGainDB, targetPeakPowerDB - peakPowerDB)
        return pow(10, gainDB / 20)
    }

    private static func writeSilence(to outputFile: AVAudioFile, format: AVAudioFormat) throws {
        let frameCount = AVAudioFrameCount(paddingDuration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw preparationError(code: 2, message: "Unable to allocate low-energy padding buffer.")
        }
        buffer.frameLength = frameCount
        guard let channels = buffer.floatChannelData else {
            throw preparationError(code: 7, message: "Low-energy padding format is unsupported.")
        }
        for channelIndex in 0 ..< Int(format.channelCount) {
            channels[channelIndex].initialize(repeating: 0, count: Int(frameCount))
        }
        try outputFile.write(from: buffer)
    }

    private static func convert(
        sourceFile: AVAudioFile,
        converter: AVAudioConverter,
        outputFile: AVAudioFile,
        outputFormat: AVAudioFormat,
        gain: Float
    ) throws {
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFile.processingFormat,
            frameCapacity: 8_192
        ) else {
            throw preparationError(code: 3, message: "Unable to allocate low-energy input buffer.")
        }

        let ratio = outputFormat.sampleRate / sourceFile.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameCapacity) * ratio)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw preparationError(code: 4, message: "Unable to allocate low-energy output buffer.")
        }

        while sourceFile.framePosition < sourceFile.length {
            inputBuffer.frameLength = 0
            try sourceFile.read(
                into: inputBuffer,
                frameCount: min(
                    inputBuffer.frameCapacity,
                    AVAudioFrameCount(sourceFile.length - sourceFile.framePosition)
                )
            )
            guard inputBuffer.frameLength > 0 else { break }

            try convertInputBuffer(
                inputBuffer,
                converter: converter,
                outputBuffer: outputBuffer,
                outputFile: outputFile,
                gain: gain
            )
        }

        try drain(
            converter: converter,
            outputBuffer: outputBuffer,
            outputFile: outputFile,
            gain: gain
        )
    }

    private static func convertInputBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputBuffer: AVAudioPCMBuffer,
        outputFile: AVAudioFile,
        gain: Float
    ) throws {
        var didProvideInput = false
        while true {
            var conversionError: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if didProvideInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            try handleConversionResult(
                status: status,
                error: conversionError,
                outputBuffer: outputBuffer,
                outputFile: outputFile,
                gain: gain
            )
            if status != .haveData { return }
        }
    }

    private static func drain(
        converter: AVAudioConverter,
        outputBuffer: AVAudioPCMBuffer,
        outputFile: AVAudioFile,
        gain: Float
    ) throws {
        while true {
            var conversionError: NSError?
            outputBuffer.frameLength = 0
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            try handleConversionResult(
                status: status,
                error: conversionError,
                outputBuffer: outputBuffer,
                outputFile: outputFile,
                gain: gain
            )
            if status != .haveData { return }
        }
    }

    private static func handleConversionResult(
        status: AVAudioConverterOutputStatus,
        error: NSError?,
        outputBuffer: AVAudioPCMBuffer,
        outputFile: AVAudioFile,
        gain: Float
    ) throws {
        if let error { throw error }
        guard status != .error else {
            throw preparationError(code: 5, message: "Low-energy audio conversion failed.")
        }
        guard outputBuffer.frameLength > 0 else { return }
        try applyGain(gain, to: outputBuffer)
        try outputFile.write(from: outputBuffer)
    }

    private static func applyGain(_ gain: Float, to buffer: AVAudioPCMBuffer) throws {
        guard let channels = buffer.floatChannelData else {
            throw preparationError(code: 6, message: "Low-energy output format is unsupported.")
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        for channelIndex in 0 ..< channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0 ..< frameCount {
                samples[frameIndex] = min(0.95, max(-0.95, samples[frameIndex] * gain))
            }
        }
    }

    private static func preparationError(code: Int, message: String) -> NSError {
        NSError(
            domain: "LowEnergyAudioPreparer",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
