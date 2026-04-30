import AVFoundation
import Foundation

enum AudioFileTranscoder {
    enum OutputFormat {
        case sourceSampleRateAndChannels
        case mono16k
    }

    static func wavFileURL(
        for audioFile: AudioFile,
        outputFormat: OutputFormat = .sourceSampleRateAndChannels,
        forceTranscode: Bool = false,
    ) throws -> URL {
        if !forceTranscode, audioFile.fileURL.pathExtension.lowercased() == "wav" {
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

        if outputFormat == .mono16k,
           audioFile.fileURL.pathExtension.lowercased() == "wav",
           let normalizedWAV = try manuallyNormalizedPCM16MonoWAV(inputURL: audioFile.fileURL)
        {
            try normalizedWAV.write(to: outputURL)
            return outputURL
        }

        let inputFile = try AVAudioFile(forReading: audioFile.fileURL)
        let outputSampleRate: Double
        let outputChannelCount: AVAudioChannelCount
        switch outputFormat {
        case .sourceSampleRateAndChannels:
            outputSampleRate = inputFile.processingFormat.sampleRate
            outputChannelCount = inputFile.processingFormat.channelCount
        case .mono16k:
            outputSampleRate = 16_000
            outputChannelCount = 1
        }
        let commonFormat: AVAudioCommonFormat = outputFormat == .mono16k ? .pcmFormatFloat32 : .pcmFormatInt16
        let isInterleaved = outputFormat == .mono16k ? false : true
        let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: outputSampleRate,
            channels: outputChannelCount,
            interleaved: isInterleaved,
        )

        guard let format else {
            throw NSError(
                domain: "AudioFileTranscoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to create WAV output format."],
            )
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)

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
        let convertedFrameCapacity = AVAudioFrameCount(Double(inputBuffer.frameCapacity) * ratio) + 1
        let outputCapacity = max(inputBuffer.frameCapacity, convertedFrameCapacity)
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
                    outStatus.pointee = .endOfStream
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

        return outputURL
    }

    private static func manuallyNormalizedPCM16MonoWAV(inputURL: URL) throws -> Data? {
        let data = try Data(contentsOf: inputURL)
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            return nil
        }

        var offset = 12
        var sampleRate: UInt32?
        var channels: UInt16?
        var bitsPerSample: UInt16?
        var pcmRange: Range<Int>?
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset + 4], encoding: .ascii)
            let chunkSize = Int(littleEndianUInt32(data, offset: offset + 4))
            let chunkStart = offset + 8
            let chunkEnd = min(chunkStart + chunkSize, data.count)
            if chunkID == "fmt ", chunkSize >= 16 {
                let audioFormat = littleEndianUInt16(data, offset: chunkStart)
                guard audioFormat == 1 else { return nil }
                channels = littleEndianUInt16(data, offset: chunkStart + 2)
                sampleRate = littleEndianUInt32(data, offset: chunkStart + 4)
                bitsPerSample = littleEndianUInt16(data, offset: chunkStart + 14)
            } else if chunkID == "data" {
                pcmRange = chunkStart..<chunkEnd
            }
            offset = chunkEnd + (chunkSize % 2)
        }

        guard sampleRate != nil,
              channels == 1,
              bitsPerSample == 16,
              let pcmRange
        else {
            return nil
        }

        let inputPCM = data[pcmRange]
        let inputFrameCount = inputPCM.count / MemoryLayout<Int16>.size
        guard inputFrameCount > 0 else {
            return wavFile(fromPCM16Mono: Data(), sampleRate: 16_000)
        }

        let outputFrameCount = max(1, Int((Double(inputFrameCount) * 16_000 / Double(sampleRate ?? 16_000)).rounded()))
        var outputPCM = Data(count: outputFrameCount * MemoryLayout<Int16>.size)
        outputPCM.withUnsafeMutableBytes { outputBytes in
            inputPCM.withUnsafeBytes { inputBytes in
                let inputSamples = inputBytes.bindMemory(to: Int16.self)
                let outputSamples = outputBytes.bindMemory(to: Int16.self)
                for outputIndex in 0..<outputFrameCount {
                    let inputIndex = min(inputFrameCount - 1, Int(Double(outputIndex) * Double(inputFrameCount) / Double(outputFrameCount)))
                    outputSamples[outputIndex] = inputSamples[inputIndex]
                }
            }
        }
        return wavFile(fromPCM16Mono: outputPCM, sampleRate: 16_000)
    }

    private static func wavFile(fromPCM16Mono pcmData: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = UInt32(36) + subchunk2Size

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianData(chunkSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(littleEndianData(UInt32(16)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(channels))
        data.append(littleEndianData(UInt32(sampleRate)))
        data.append(littleEndianData(byteRate))
        data.append(littleEndianData(blockAlign))
        data.append(littleEndianData(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianData(subchunk2Size))
        data.append(pcmData)
        return data
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }
}
