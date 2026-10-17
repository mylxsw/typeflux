import AVFoundation
import Testing
@testable import Typeflux

private actor AudioBoundsGate {
    private var entered = false, released = false
    private var entries: [CheckedContinuation<Void, Never>] = []
    private var exits: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true; entries.forEach { $0.resume() }; entries.removeAll()
        if !released { await withCheckedContinuation { exits.append($0) } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entries.append($0) } } }
    func release() { released = true; exits.forEach { $0.resume() }; exits.removeAll() }
}
private actor HeldAudioInput: RealtimeTranscriptionSession {
    let gate = AudioBoundsGate()
    private(set) var samples: [Int16] = []
    private(set) var cancels = 0
    func start() async {}
    func append(_ buffer: AVAudioPCMBuffer) async {
        samples.append(buffer.int16ChannelData![0][0])
        if samples.count == 1 { await gate.hold() }
    }
    func finish() async -> String { "must not accept missing input" }
    func cancel() async { cancels += 1 }
    func snapshot() -> (samples: [Int16], cancels: Int) { (samples, cancels) }
}
private actor HeldEncodedAudio: PCM16RealtimeTranscriptionSession {
    let connection = AudioBoundsGate(), write = AudioBoundsGate(), cancellation = AudioBoundsGate()
    let holdConnection: Bool, holdWrite: Bool
    private(set) var bytes = Data(), finishes = 0, cancels = 0
    init(connection: Bool = false, write: Bool = false) { holdConnection = connection; holdWrite = write }
    func start() async { if holdConnection { await connection.hold() } }
    func appendPCM16(_ data: Data) async {
        bytes.append(data)
        if holdWrite { await write.hold() }
    }
    func finish() async -> String { finishes += 1; return "complete" }
    func cancel() async { cancels += 1; await cancellation.release() }
    func snapshot() -> (bytes: Data, finishes: Int, cancels: Int) { (bytes, finishes, cancels) }
}

@Suite("Bounded realtime audio input", .exclusiveUIState)
@MainActor struct RealtimeAudioBoundsTests {
    private func pcm(_ value: Int16 = 7, frames: UInt32 = 16, channels: UInt32 = 1) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: channels, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.int16ChannelData![0].update(repeating: value, count: Int(frames * channels))
        return buffer
    }
    private func failed(_ pump: RealtimeAudioBufferPump, cancellation: Bool = false) async {
        do { try await pump.finishInput(); Issue.record("Incomplete audio accepted") }
        catch { #expect(cancellation ? error is CancellationError : error is RealtimeAudioBufferError) }
    }
    private func failed(_ session: BufferedRealtimeTranscriptionSession) async {
        do { _ = try await session.finish(); Issue.record("Incomplete PCM accepted") }
        catch { #expect(error is RealtimeAudioBufferError) }
    }

    @Test func pumpOverflowRetainsActualAppendAndRejectsTruncatedCompletion() async throws {
        let session = HeldAudioInput(), pump = RealtimeAudioBufferPump(session: session, maximumQueuedBuffers: 1)
        pump.append(try pcm(1)); await session.gate.wait()
        pump.append(try pcm(2)); pump.append(try pcm(3)); pump.append(try pcm(4))
        let state1 = await session.snapshot()
        #expect(state1.samples == [1] && state1.cancels == 0)
        await session.gate.release()
        await failed(pump)
        let state2 = await session.snapshot()
        #expect(state2.samples == [1] && state2.cancels == 1)
    }

    @Test func pumpCancellationDiscardsPendingAndCollectionWaitsForEnteredAppend() async throws {
        let session = HeldAudioInput(), pump = RealtimeAudioBufferPump(session: session, maximumQueuedBuffers: 0)
        pump.append(try pcm(1)); await session.gate.wait()
        pump.append(try pcm(2)); pump.cancel(); pump.append(try pcm(3))
        let state3 = await session.snapshot()
        #expect(state3.samples == [1])
        await session.gate.release(); await failed(pump, cancellation: true)
        let state4 = await session.snapshot()
        #expect(state4.samples == [1] && state4.cancels == 1)
    }

    @Test(arguments: [UInt32(0), UInt32(131073)]) func invalidOrOversizedPumpInputNeverReachesSession(_ frames: UInt32) async throws {
        let session = HeldAudioInput(), pump = RealtimeAudioBufferPump(session: session)
        let buffer = try pcm(frames: max(1, frames)); buffer.frameLength = frames
        pump.append(buffer); await failed(pump)
        let state5 = await session.snapshot()
        #expect(state5.samples.isEmpty && state5.cancels == 1)
    }

    @Test func exactByteLimitAndHealthyFinishRetainProducerSnapshot() async throws {
        let session = HeldAudioInput(), pump = RealtimeAudioBufferPump(session: session)
        let first = try pcm(1, frames: 131072)
        pump.append(first); first.int16ChannelData![0][0] = 99
        await session.gate.wait(); await session.gate.release()
        try await pump.finishInput()
        pump.append(try pcm(2))
        let state6 = await session.snapshot()
        #expect(state6.samples == [1] && state6.cancels == 0)
    }

    @Test func queuedConnectionOverflowNeverSendsOrFinishesUpstream() async {
        let upstream = HeldEncodedAudio(connection: true), session = BufferedRealtimeTranscriptionSession(upstream: upstream, maximumQueuedChunks: 1)
        await session.start(); await upstream.connection.wait()
        let overflow = Task { await session.appendEncodedPCM16(Data(repeating: 3, count: CloudASRAudioConverter.chunkSize * 2)) }
        await upstream.cancellation.hold()
        let state7 = await upstream.snapshot()
        #expect(state7.bytes.isEmpty && state7.finishes == 0)
        await upstream.connection.release(); await overflow.value; await failed(session)
        let state8 = await upstream.snapshot()
        #expect(state8.bytes.isEmpty && state8.finishes == 0 && state8.cancels > 0)
    }

    @Test func slowWriterOverflowKeepsOneEnteredEffectAndRefusesStopSuccess() async {
        let upstream = HeldEncodedAudio(write: true), session = BufferedRealtimeTranscriptionSession(upstream: upstream, maximumQueuedChunks: 1)
        let first = Data(repeating: 1, count: CloudASRAudioConverter.chunkSize)
        await session.appendEncodedPCM16(first); await upstream.write.wait()
        let overflow = Task { await session.appendEncodedPCM16(Data(repeating: 2, count: CloudASRAudioConverter.chunkSize * 2)) }
        await upstream.cancellation.hold()
        let state9 = await upstream.snapshot()
        #expect(state9.bytes == first && state9.finishes == 0)
        await upstream.write.release(); await overflow.value; await failed(session)
        let state10 = await upstream.snapshot()
        #expect(state10.bytes == first && state10.finishes == 0)
    }

    @Test func finalPartialChunkOverflowFailsRatherThanReturningShortTranscript() async {
        let upstream = HeldEncodedAudio(connection: true), session = BufferedRealtimeTranscriptionSession(upstream: upstream, maximumQueuedChunks: 1)
        await session.start(); await upstream.connection.wait()
        await session.appendEncodedPCM16(Data(repeating: 1, count: CloudASRAudioConverter.chunkSize + 2))
        let finish = Task { await failed(session) }
        await upstream.cancellation.hold()
        await upstream.connection.release(); await finish.value
        let state11 = await upstream.snapshot()
        #expect(state11.bytes.isEmpty && state11.finishes == 0)
    }

    @Test func healthyEncodedInputPreservesOrderRemainderAndOneFinalResult() async throws {
        let upstream = HeldEncodedAudio(), session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        let prefix = Data(repeating: 1, count: CloudASRAudioConverter.chunkSize), tail = Data([2, 3, 4, 5])
        await session.appendEncodedPCM16(prefix); await session.appendEncodedPCM16(tail)
        #expect(try await session.finish() == "complete")
        await session.appendEncodedPCM16(Data([9]))
        let state12 = await upstream.snapshot()
        #expect(state12.bytes == prefix + tail && state12.finishes == 1 && state12.cancels == 0)
    }

    @Test func encodedInputLimitAndRawEmptyBufferFailBeforeConversion() async throws {
        for raw in [false, true] {
            let upstream = HeldEncodedAudio(), session = BufferedRealtimeTranscriptionSession(upstream: upstream)
            if raw {
                let empty = try pcm(); empty.frameLength = 0
                await session.append(empty)
            } else {
                await session.appendEncodedPCM16(Data(repeating: 0, count: RealtimePCM16AudioEncoder.maximumOutputBytes + 1))
            }
            await failed(session)
            let state13 = await upstream.snapshot()
            #expect(state13.bytes.isEmpty && state13.finishes == 0)
        }
    }

    @Test func cancelledEncodedSessionDoesNotRestartAndFinishCollectsItsWriter() async {
        let upstream = HeldEncodedAudio(connection: true), session = BufferedRealtimeTranscriptionSession(upstream: upstream)
        await session.start(); await upstream.connection.wait()
        let cancel = Task { await session.cancel() }
        await upstream.cancellation.hold(); await upstream.connection.release(); await cancel.value
        await session.appendEncodedPCM16(Data([1, 2]))
        do { _ = try await session.finish(); Issue.record("Cancelled stream succeeded") }
        catch { #expect(error is CancellationError) }
        let state14 = await upstream.snapshot()
        #expect(state14.bytes.isEmpty && state14.finishes == 0)
    }

    @Test func heapSlicesResetAndFlushKeepOwnedZeroBasedPCMWithoutNativeConversion() {
        let storage = Data((0..<10_000).map { UInt8($0 % 251) })
        let sliced = storage.dropFirst(37)
        var chunker = PCM16FrameChunker(chunkSize: 3200)
        let chunks = chunker.append(sliced) + chunker.flush()
        #expect(chunks.allSatisfy { $0.startIndex == 0 })
        #expect(chunks.reduce(into: Data(), { $0.append($1) }) == Data(sliced))
        for count in [3200, 6400, 6402, 9600] {
            _ = chunker.append(Data(repeating: 7, count: count))
            chunker.reset()
            #expect(chunker.flush().isEmpty)
            #expect(chunker.append(Data([1, 2])).isEmpty)
            #expect(chunker.flush() == [Data([1, 2])])
        }
        var unframed = PCM16FrameChunker(chunkSize: 0)
        let whole = unframed.append(sliced)
        #expect(whole.first?.startIndex == 0 && whole.first == Data(sliced))
        #expect(unframed.flush().isEmpty)
    }

    @Test func outputAllocationRejectsNonFiniteAndExtremeRatiosBeforeConverter() throws {
        #expect(try RealtimePCM16AudioEncoder.targetCapacity(frames: 1600, sampleRate: 16000) == 1856)
        for rate in [Double.nan, .infinity, -.infinity, 0, -1, .leastNonzeroMagnitude] {
            #expect(throws: RealtimeAudioBufferError.self) { try RealtimePCM16AudioEncoder.targetCapacity(frames: UInt32.max, sampleRate: rate) }
        }
        #expect(throws: RealtimeAudioBufferError.self) { try RealtimePCM16AudioEncoder.targetCapacity(frames: 0, sampleRate: 16000) }
        #expect(throws: RealtimeAudioBufferError.self) { try RealtimePCM16AudioEncoder.targetCapacity(frames: UInt32.max, sampleRate: 1) }
    }

    @Test func planarByteAdmissionAndFailedResultAdapterArePure() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)); buffer.frameLength = 16
        #expect(AudioPCMBufferSnapshot.byteCount(buffer, maximumBytes: 128) == 128)
        #expect(AudioPCMBufferSnapshot.byteCount(buffer, maximumBytes: 127) == nil)
        #expect(AudioPCMBufferSnapshot.byteCount(buffer, maximumBytes: 0) == nil)
        let failed = FailedRealtimeAudioInput(RealtimeAudioBufferError.capacityExceeded)
        await failed.start(); await failed.append(buffer); await failed.cancel()
        do { _ = try await failed.finish(); Issue.record("Failed input accepted") }
        catch { #expect(error is RealtimeAudioBufferError) }
    }
}
