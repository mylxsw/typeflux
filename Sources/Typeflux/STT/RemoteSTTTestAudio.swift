import Foundation

enum RemoteSTTTestAudio {
    static func pcm16MonoSilence(sampleRate: Int = 16000, durationMs: Int = 320) -> Data {
        let frameCount = max(1, sampleRate * durationMs / 1000)
        return Data(count: frameCount * MemoryLayout<Int16>.size)
    }

    static func wavSilence(sampleRate: Int = 16000, durationMs: Int = 320) -> Data {
        let pcmData = pcm16MonoSilence(sampleRate: sampleRate, durationMs: durationMs)
        return wavFile(fromPCM16Mono: pcmData, sampleRate: sampleRate)
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

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return Data(bytes: &littleEndian, count: MemoryLayout<T>.size)
    }
}
