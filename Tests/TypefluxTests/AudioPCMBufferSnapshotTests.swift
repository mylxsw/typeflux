import AVFoundation
import Foundation
@testable import Typeflux
import XCTest

final class AudioPCMBufferSnapshotTests: XCTestCase {
    func testPreservesEverySampleForInterleavedAndPlanarPCMFormats() throws {
        for commonFormat: AVAudioCommonFormat in [
            .pcmFormatFloat32,
            .pcmFormatFloat64,
            .pcmFormatInt16,
            .pcmFormatInt32
        ] {
            for interleaved in [false, true] {
                let format = try XCTUnwrap(AVAudioFormat(
                    commonFormat: commonFormat, sampleRate: 48000, channels: 2, interleaved: interleaved
                ))
                let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
                source.frameLength = 17
                let planes = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
                for (channel, plane) in planes.enumerated() {
                    let data = try XCTUnwrap(plane.mData).assumingMemoryBound(to: UInt8.self)
                    for index in 0 ..< Int(plane.mDataByteSize) {
                        data[index] = UInt8((index + channel * 19) % 251)
                    }
                }
                let expected = bytes(in: source)
                let snapshot = try XCTUnwrap(AudioPCMBufferSnapshot.copy(source))
                XCTAssertFalse(snapshot === source)
                XCTAssertEqual(snapshot.format, source.format)
                XCTAssertEqual(snapshot.frameLength, source.frameLength)
                XCTAssertEqual(bytes(in: snapshot), expected)

                for plane in planes {
                    try memset(XCTUnwrap(plane.mData), 0, Int(plane.mDataByteSize))
                }
                XCTAssertEqual(bytes(in: snapshot), expected, "Producer mutations must not change queued audio")
            }
        }
    }

    func testRejectsEmptyAudio() throws {
        let source = try makeFreshBuffer()
        source.frameLength = 0
        XCTAssertNil(AudioPCMBufferSnapshot.copy(source))
    }

    func testRejectsMissingSampleData() throws {
        let source = try makeMalformedBuffer()
        let planes = try UnsafeMutableAudioBufferListPointer(XCTUnwrap(source.overriddenBufferList))
        planes[0].mData = nil
        XCTAssertNil(AudioPCMBufferSnapshot.copy(source))
    }

    func testRejectsTruncatedSampleData() throws {
        let source = try makeMalformedBuffer()
        let planes = try UnsafeMutableAudioBufferListPointer(XCTUnwrap(source.overriddenBufferList))
        planes[0].mDataByteSize -= 1
        XCTAssertNil(AudioPCMBufferSnapshot.copy(source))
    }

    func testCopyNeverInitializesTheProducersChannelPointers() throws {
        let source = try makeMalformedBuffer()
        XCTAssertNotNil(AudioPCMBufferSnapshot.copy(source))
        XCTAssertEqual(source.channelDataReadCount, 0)
    }

    func testFreshRecordingBuffersAndPublishedSnapshotsCanBeReadConcurrently() throws {
        for _ in 0 ..< 10000 {
            // Fill through the buffer list, just as the converter does, without
            // initializing the producer's lazy floatChannelData pointer array.
            let source = try makeFreshBuffer()
            let snapshot = try XCTUnwrap(AudioPCMBufferSnapshot.copy(source))
            DispatchQueue.concurrentPerform(iterations: 4) { consumer in
                let buffer = consumer == 0 ? source : snapshot
                guard let channels = buffer.floatChannelData else {
                    XCTFail("Float audio must have channel pointers")
                    return
                }
                let address = UnsafeRawPointer(channels).load(as: UInt.self)
                guard address != 0 else {
                    XCTFail("Published audio must never expose an uninitialized channel pointer")
                    return
                }
                XCTAssertEqual(channels[0][0], 0.25)
                XCTAssertEqual(channels[0][511], 0.25)
            }
        }
    }

    private func makeFreshBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let planes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let samples = try XCTUnwrap(planes[0].mData).assumingMemoryBound(to: Float.self)
        samples.update(repeating: 0.25, count: 512)
        return buffer
    }

    private func bytes(in buffer: AVAudioPCMBuffer) -> [Data] {
        UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList)).map {
            Data(bytes: $0.mData!, count: Int($0.mDataByteSize))
        }
    }

    private func makeMalformedBuffer() throws -> SnapshotSourcePCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let source = try XCTUnwrap(SnapshotSourcePCMBuffer(pcmFormat: format, frameCapacity: 512))
        source.frameLength = 512
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        list.initialize(to: source.audioBufferList.pointee)
        source.overriddenBufferList = list
        return source
    }
}

private final class SnapshotSourcePCMBuffer: AVAudioPCMBuffer {
    var overriddenBufferList: UnsafeMutablePointer<AudioBufferList>?
    private(set) var channelDataReadCount = 0

    override var audioBufferList: UnsafePointer<AudioBufferList> {
        overriddenBufferList.map { UnsafePointer($0) } ?? super.audioBufferList
    }

    override var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? {
        channelDataReadCount += 1
        return super.floatChannelData
    }

    deinit {
        overriddenBufferList?.deinitialize(count: 1)
        overriddenBufferList?.deallocate()
    }
}
