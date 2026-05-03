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
            withIntermediateDirectories: true,
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        do {
            try convertWithAVFoundation(inputURL: audioFile.fileURL, outputURL: outputURL)
        } catch {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            try convertWithAFConvert(inputURL: audioFile.fileURL, outputURL: outputURL, originalError: error)
        }

        return outputURL
    }

    private static func convertWithAVFoundation(inputURL: URL, outputURL: URL) throws {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: inputFile.processingFormat.sampleRate,
            channels: inputFile.processingFormat.channelCount,
            interleaved: true,
        )

        guard let format else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create WAV output format."],
            )
        }

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved,
        )

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: format) else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create audio converter."],
            )
        }

        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: 8192,
        )

        guard let inputBuffer else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."],
            )
        }

        let ratio = format.sampleRate / inputFile.processingFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameCapacity) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputCapacity) else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate converted audio buffer."],
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
                    userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed."],
                )
            }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }
        }
    }

    private static func convertWithAFConvert(inputURL: URL, outputURL: URL, originalError: Error) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f",
            "WAVE",
            "-d",
            "LEI16",
            inputURL.path,
            outputURL.path,
        ]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to transcode audio file to WAV.",
                    NSLocalizedFailureReasonErrorKey: stderr.isEmpty ? "afconvert exited with status \(process.terminationStatus)." : stderr,
                    NSUnderlyingErrorKey: originalError,
                ],
            )
        }
    }
}
