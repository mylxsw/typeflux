import XCTest
@testable import Typeflux

final class RemoteSTTTestAudioTests: XCTestCase {

    // MARK: - PCM silence

    func testPCM16MonoSilenceDefaultSize() {
        let data = RemoteSTTTestAudio.pcm16MonoSilence()
        // 16000 Hz * 320ms / 1000 = 5120 frames * 2 bytes = 10240
        XCTAssertEqual(data.count, 10240)
    }

    func testPCM16MonoSilenceCustomParameters() {
        let data = RemoteSTTTestAudio.pcm16MonoSilence(sampleRate: 48000, durationMs: 100)
        // 48000 * 100 / 1000 = 4800 frames * 2 bytes = 9600
        XCTAssertEqual(data.count, 9600)
    }

    func testPCM16MonoSilenceContentIsZeros() {
        let data = RemoteSTTTestAudio.pcm16MonoSilence(sampleRate: 16000, durationMs: 10)
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }

    func testPCM16MonoSilenceMinimumOneFrame() {
        let data = RemoteSTTTestAudio.pcm16MonoSilence(sampleRate: 1, durationMs: 1)
        XCTAssertEqual(data.count, 2) // 1 frame * 2 bytes
    }

    // MARK: - WAV silence

    func testWavSilenceHeaderStructure() {
        let data = RemoteSTTTestAudio.wavSilence(sampleRate: 16000, durationMs: 100)

        // Check RIFF header
        let riffTag = String(data: data[0..<4], encoding: .ascii)
        XCTAssertEqual(riffTag, "RIFF")

        // Check WAVE format
        let waveTag = String(data: data[8..<12], encoding: .ascii)
        XCTAssertEqual(waveTag, "WAVE")

        // Check fmt  subchunk
        let fmtTag = String(data: data[12..<16], encoding: .ascii)
        XCTAssertEqual(fmtTag, "fmt ")

        // Check data subchunk
        let dataTag = String(data: data[36..<40], encoding: .ascii)
        XCTAssertEqual(dataTag, "data")
    }

    func testWavSilenceSize() {
        let data = RemoteSTTTestAudio.wavSilence(sampleRate: 16000, durationMs: 100)
        // PCM data: 16000 * 100/1000 * 2 = 3200 bytes
        // WAV header: 44 bytes
        XCTAssertEqual(data.count, 3200 + 44)
    }

    func testWavSilenceAudioFormatIsPCM() {
        let data = RemoteSTTTestAudio.wavSilence()
        // Audio format at byte 20-21 (little endian), PCM = 1
        let audioFormat = UInt16(data[20]) | (UInt16(data[21]) << 8)
        XCTAssertEqual(audioFormat, 1)
    }

    func testWavSilenceChannelIsMono() {
        let data = RemoteSTTTestAudio.wavSilence()
        // Channels at byte 22-23
        let channels = UInt16(data[22]) | (UInt16(data[23]) << 8)
        XCTAssertEqual(channels, 1)
    }

    func testWavSilenceSampleRate() {
        let data = RemoteSTTTestAudio.wavSilence(sampleRate: 44100)
        // Sample rate at byte 24-27
        let sampleRate = UInt32(data[24]) | (UInt32(data[25]) << 8) |
            (UInt32(data[26]) << 16) | (UInt32(data[27]) << 24)
        XCTAssertEqual(sampleRate, 44100)
    }

    func testWavSilenceBitsPerSample() {
        let data = RemoteSTTTestAudio.wavSilence()
        // Bits per sample at byte 34-35
        let bps = UInt16(data[34]) | (UInt16(data[35]) << 8)
        XCTAssertEqual(bps, 16)
    }

    func testWavSilenceChunkSizeConsistency() {
        let data = RemoteSTTTestAudio.wavSilence(sampleRate: 16000, durationMs: 200)
        // Chunk size at byte 4-7: total size - 8
        let chunkSize = UInt32(data[4]) | (UInt32(data[5]) << 8) |
            (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        XCTAssertEqual(Int(chunkSize), data.count - 8)
    }
}
