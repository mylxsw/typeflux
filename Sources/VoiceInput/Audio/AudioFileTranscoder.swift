import AVFoundation
import Foundation

enum AudioFileTranscoder {
    static func wavFileURL(for audioFile: AudioFile) throws -> URL {
        if audioFile.fileURL.pathExtension.lowercased() == "wav" {
            return audioFile.fileURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-transcoded", isDirectory: true)
            .appendingPathComponent(audioFile.fileURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("wav")

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let inputFile = try AVAudioFile(forReading: audioFile.fileURL)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: inputFile.processingFormat.sampleRate,
            channels: inputFile.processingFormat.channelCount,
            interleaved: true
        )

        guard let format else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create WAV output format."]
            )
        }

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: format) else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter."]
            )
        }

        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: 8_192
        )

        guard let inputBuffer else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."]
            )
        }

        let ratio = format.sampleRate / inputFile.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameCapacity) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate converted audio buffer."]
            )
        }

        while true {
            try inputFile.read(into: inputBuffer)
            if inputBuffer.frameLength == 0 {
                break
            }

            var conversionError: NSError?
            var didProvideInput = false
            outputBuffer.frameLength = 0

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw conversionError
            }

            guard status != .error else {
                throw NSError(
                    domain: "AudioFileTranscoder",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."]
                )
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
        }

        return outputURL
    }
}
