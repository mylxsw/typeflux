import AVFoundation
import XCTest
@testable import Typeflux

final class RealtimeTranscriptionSessionTests: XCTestCase {
    func testPCM16FrameChunkerKeepsRemainderUntilFlush() {
        var chunker = PCM16FrameChunker(chunkSize: 4)

        XCTAssertEqual(chunker.append(Data([1, 2, 3])), [])
        XCTAssertEqual(chunker.append(Data([4, 5, 6, 7, 8])), [
            Data([1, 2, 3, 4]),
            Data([5, 6, 7, 8]),
        ])
        XCTAssertEqual(chunker.append(Data([9, 10])), [])
        XCTAssertEqual(chunker.flush(), [Data([9, 10])])
    }

    func testPCM16FrameChunkerRebasesChunksAfterDrainingBuffer() {
        var chunker = PCM16FrameChunker(chunkSize: 4)

        let chunks = chunker.append(Data([1, 2, 3, 4, 5, 6, 7, 8]))

        XCTAssertEqual(chunks, [
            Data([1, 2, 3, 4]),
            Data([5, 6, 7, 8]),
        ])
        XCTAssertEqual(chunks.map(\.startIndex), [0, 0])
        XCTAssertEqual(chunker.append(Data([9, 10])), [])
        XCTAssertEqual(chunker.flush(), [Data([9, 10])])
    }

    func testBufferedSessionQueuesAudioUntilUpstreamStartCompletes() async throws {
        let upstream = DelayedStartPCMStream(finalText: "done")
        let session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        let buffer = try makeFloatBuffer(frameCount: 1_600)

        await session.start()
        await session.append(buffer)
        let chunkCountBeforeStart = await upstream.sentChunkCount()
        XCTAssertEqual(chunkCountBeforeStart, 0)

        await upstream.releaseStart()
        let finalText = try await session.finish()

        XCTAssertEqual(finalText, "done")
        let chunkCountAfterFinish = await upstream.sentChunkCount()
        let byteCountAfterFinish = await upstream.sentByteCount()
        XCTAssertEqual(chunkCountAfterFinish, 1)
        XCTAssertEqual(byteCountAfterFinish, CloudASRAudioConverter.chunkSize)
    }

    func testBufferedSessionThrowsStartErrorFromFinish() async throws {
        let upstream = FailingStartPCMStream()
        let session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        let buffer = try makeFloatBuffer(frameCount: 1_600)

        await session.start()
        await session.append(buffer)

        do {
            _ = try await session.finish()
            XCTFail("Expected realtime start failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FailingStartPCMStream")
        }
    }

    func testDeferredPCM16SessionResolvesUpstreamOnStart() async throws {
        let upstream = DelayedStartPCMStream(finalText: "deferred")
        let factory = DelayedPCMStreamFactory(upstream: upstream)
        let session = DeferredPCM16RealtimeTranscriptionSession {
            await factory.makeUpstream()
        }

        let startTask = Task {
            try await session.start()
        }
        await factory.waitUntilRequested()
        let requestCountBeforeRelease = await factory.requestCount()
        let startCountBeforeRelease = await upstream.startCallCount()
        XCTAssertEqual(requestCountBeforeRelease, 1)
        XCTAssertEqual(startCountBeforeRelease, 0)

        await factory.release()
        await upstream.waitUntilStartCalled()
        await upstream.releaseStart()
        try await startTask.value

        try await session.appendPCM16(Data([1, 2, 3]))
        let finalText = try await session.finish()

        let startCountAfterFinish = await upstream.startCallCount()
        let sentByteCount = await upstream.sentByteCount()
        XCTAssertEqual(finalText, "deferred")
        XCTAssertEqual(startCountAfterFinish, 1)
        XCTAssertEqual(sentByteCount, 3)
    }

    private func makeFloatBuffer(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: CloudASRAudioConverter.targetSampleRate,
            channels: 1,
            interleaved: false,
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        for index in 0 ..< Int(frameCount) {
            channel[index] = sinf(Float(index) / 20.0) * 0.2
        }
        return buffer
    }
}

private actor DelayedStartPCMStream: PCM16RealtimeTranscriptionSession {
    private let finalText: String
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startRequestedContinuation: CheckedContinuation<Void, Never>?
    private var chunks: [Data] = []
    private var starts = 0

    init(finalText: String) {
        self.finalText = finalText
    }

    func start() async throws {
        starts += 1
        startRequestedContinuation?.resume()
        startRequestedContinuation = nil
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func appendPCM16(_ data: Data) async throws {
        chunks.append(data)
    }

    func finish() async throws -> String {
        finalText
    }

    func cancel() async {
        startContinuation?.resume()
        startContinuation = nil
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func sentChunkCount() -> Int {
        chunks.count
    }

    func sentByteCount() -> Int {
        chunks.reduce(0) { $0 + $1.count }
    }

    func startCallCount() -> Int {
        starts
    }

    func waitUntilStartCalled() async {
        if starts > 0 { return }
        await withCheckedContinuation { continuation in
            startRequestedContinuation = continuation
        }
    }
}

private actor FailingStartPCMStream: PCM16RealtimeTranscriptionSession {
    func start() async throws {
        throw NSError(domain: "FailingStartPCMStream", code: 1)
    }

    func appendPCM16(_: Data) async throws {}

    func finish() async throws -> String {
        ""
    }

    func cancel() async {}
}

private actor DelayedPCMStreamFactory {
    private let upstream: any PCM16RealtimeTranscriptionSession
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requests = 0

    init(upstream: any PCM16RealtimeTranscriptionSession) {
        self.upstream = upstream
    }

    func makeUpstream() async -> any PCM16RealtimeTranscriptionSession {
        requests += 1
        requestContinuation?.resume()
        requestContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return upstream
    }

    func waitUntilRequested() async {
        if requests > 0 { return }
        await withCheckedContinuation { continuation in
            requestContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func requestCount() -> Int {
        requests
    }
}
