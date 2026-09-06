import AVFoundation
import XCTest

@testable import Typeflux

final class AudioInputSignalTrackerTests: XCTestCase {
    func testDigitalSilenceIsCountedButNeverRemoved() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        buffer.floatChannelData![0].update(repeating: 0, count: 320)
        var tracker = AudioInputSignalTracker()
        let base = Date()
        for _ in 0..<30 { tracker.observe(buffer, receivedAt: base) }
        XCTAssertNil(tracker.firstSignalAt)
        XCTAssertEqual(tracker.leadingZeroDuration, 0.6, accuracy: 0.000001)
        buffer.floatChannelData![0][40] = 0.000001
        tracker.observe(buffer, receivedAt: base.addingTimeInterval(0.6))
        XCTAssertEqual(tracker.leadingZeroDuration, 0.6025, accuracy: 0.000001)
        XCTAssertEqual(buffer.frameLength, 320)
        XCTAssertEqual(buffer.floatChannelData![0][40], 0.000001)
        tracker.observe(buffer, receivedAt: base.addingTimeInterval(1))
        XCTAssertEqual(tracker.firstSignalAt, base.addingTimeInterval(0.6))
    }

    func testSignalOnEitherChannelIsRecognizedAcrossPCMFormats() throws {
        for common: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32] {
            for interleaved in [false, true] {
                let format = try XCTUnwrap(
                    AVAudioFormat(
                        commonFormat: common, sampleRate: 16000,
                        channels: 2, interleaved: interleaved))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
                buffer.frameLength = 4
                let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for item in list { memset(item.mData!, 0, Int(item.mDataByteSize)) }
                let plane = interleaved ? 0 : 1
                let index = interleaved ? 5 : 2
                switch common {
                case .pcmFormatFloat32: buffer.floatChannelData![plane][index] = -0.000001
                case .pcmFormatFloat64: list[plane].mData!.assumingMemoryBound(to: Double.self)[index] = -0.000001
                case .pcmFormatInt16: buffer.int16ChannelData![plane][index] = 1
                case .pcmFormatInt32: buffer.int32ChannelData![plane][index] = 1
                default: break
                }
                XCTAssertEqual(AudioInputSignalTracker.firstNonzeroFrame(in: buffer), 2)
            }
        }
    }

    func testEmptyAndNonfiniteSamplesDoNotReportAReadyMicrophone() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        XCTAssertNil(AudioInputSignalTracker.firstNonzeroFrame(in: buffer))
        buffer.frameLength = 3
        buffer.floatChannelData![0][0] = .nan
        buffer.floatChannelData![0][1] = .infinity
        buffer.floatChannelData![0][2] = -0.0
        XCTAssertNil(AudioInputSignalTracker.firstNonzeroFrame(in: buffer))
    }

    func testDelayedHotkeyDeliveryKeepsThePhysicalPressTime() {
        let context = HotkeyEventContext(uptime: ProcessInfo.processInfo.systemUptime - 0.25)
        XCTAssertEqual(Date().timeIntervalSince(context.detectedAt), 0.25, accuracy: 0.02)
        let explicit = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(HotkeyEventContext(detectedAt: explicit, uptime: 10).detectedAt, explicit)
    }
}
