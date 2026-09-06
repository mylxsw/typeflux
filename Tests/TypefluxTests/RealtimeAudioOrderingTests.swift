import AVFoundation
import XCTest

@testable import Typeflux

final class RealtimeAudioOrderingTests: XCTestCase {
    func testLiveAudioCannotOvertakeBufferedPrefixDuringConnectionFlush() async throws {
        let upstream = SuspendedWritePCMStream()
        let session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        await session.start()
        await session.append(try buffer(value: 100))
        await session.append(try buffer(value: 200))
        await upstream.releaseStart()
        await upstream.waitForFirstWrite()
        await session.append(try buffer(value: 300))
        let beforeRelease = await upstream.values
        await upstream.releaseWrite()
        _ = try await session.finish()
        let finalValues = await upstream.values
        XCTAssertEqual(beforeRelease, [100], "Live audio must queue behind the entire captured prefix")
        XCTAssertEqual(finalValues, [100, 200, 300])
    }

    func testStopWaitsForTheEntirePrefixToFinishSending() async throws {
        let upstream = SuspendedWritePCMStream()
        let session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        await session.start()
        await session.append(try buffer(value: 100))
        await session.append(try buffer(value: 200))
        await upstream.releaseStart()
        await upstream.waitForFirstWrite()
        let finish = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(20))
        let stoppedEarly = await upstream.didFinish
        XCTAssertFalse(stoppedEarly)
        await upstream.releaseWrite()
        _ = try await finish.value
        let values = await upstream.values
        XCTAssertEqual(values, [100, 200])
        let didFinish = await upstream.didFinish
        XCTAssertTrue(didFinish)
    }

    func testCancellationDiscardsUnsentAudioAndNeverSendsStopAsSuccess() async throws {
        let upstream = SuspendedWritePCMStream()
        let session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        await session.start()
        await session.append(try buffer(value: 100))
        await session.append(try buffer(value: 200))
        await upstream.releaseStart()
        await upstream.waitForFirstWrite()
        await session.cancel()
        do {
            _ = try await session.finish()
            XCTFail("Cancelled input cannot become a successful transcript")
        } catch is CancellationError {}
        let values = await upstream.values
        XCTAssertEqual(values, [100])
        let didFinish = await upstream.didFinish
        XCTAssertFalse(didFinish)
    }

    private func buffer(value: Int16) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: CloudASRAudioConverter.targetSampleRate, channels: 1, interleaved: true))
        let frames = AVAudioFrameCount(CloudASRAudioConverter.chunkSize / 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.int16ChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }
}

private actor SuspendedWritePCMStream: PCM16RealtimeTranscriptionSession {
    private var startReleased = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var firstWriteWaiter: CheckedContinuation<Void, Never>?
    private var writeWaiter: CheckedContinuation<Void, Never>?
    private(set) var values: [Int16] = []
    private(set) var didFinish = false

    func start() async {
        if !startReleased { await withCheckedContinuation { startWaiter = $0 } }
    }
    func releaseStart() {
        startReleased = true
        startWaiter?.resume()
        startWaiter = nil
    }
    func appendPCM16(_ data: Data) async {
        values.append(data.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        if values.count == 1 {
            firstWriteWaiter?.resume()
            firstWriteWaiter = nil
            await withCheckedContinuation { writeWaiter = $0 }
        }
    }
    func waitForFirstWrite() async {
        if values.isEmpty { await withCheckedContinuation { firstWriteWaiter = $0 } }
    }
    func releaseWrite() {
        writeWaiter?.resume()
        writeWaiter = nil
    }
    func finish() async throws -> String {
        didFinish = true
        return "done"
    }
    func cancel() async {
        releaseStart()
        releaseWrite()
    }
}
