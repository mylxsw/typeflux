import AVFoundation
import XCTest
@testable import Typeflux

final class RecordingQueueBoundsTests: XCTestCase {
    private func pcm(frames: UInt32 = 16, capacity: UInt32 = 16) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, capacity)))
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: 0.25, count: Int(frames))
        return buffer
    }

    func testRelayCountOverflowRefusesIncompletePrefixAndExplicitDiscardReopens() throws {
        let relay = RecordingStartupAudioBufferRelay(maximumBuffers: 2)
        let buffer = try pcm(capacity: 65536)
        let received = Date(timeIntervalSince1970: 5)
        relay.append(buffer, receivedAt: received)
        var capacities: [UInt32] = []
        XCTAssertNil(relay.activate { capacities.append($0.frameCapacity) })
        XCTAssertEqual(capacities, [16]) // Frame length, not the producer's large allocation.
        relay.append(buffer)
        XCTAssertEqual(capacities, [16, 65536]) // Active delivery remains zero-copy.
        let waiting = RecordingStartupAudioBufferRelay(maximumBuffers: 2)
        waiting.append(buffer); waiting.append(buffer); waiting.append(buffer)
        XCTAssertEqual(waiting.bufferedFrameCountForTesting, 0)
        XCTAssertNotNil(waiting.activate { _ in XCTFail("Incomplete prefix delivered") })
        waiting.append(buffer)
        XCTAssertNotNil(waiting.activate { _ in XCTFail("Failure replayed") })
        waiting.discardBufferedAudio()
        XCTAssertNil(waiting.firstBufferReceivedAt)
        waiting.append(buffer)
        var count = 0
        XCTAssertNil(waiting.activate { _ in count += 1 })
        XCTAssertEqual(count, 1)
        XCTAssertEqual(relay.firstBufferReceivedAt, received)
    }

    func testRelayByteLimitInvalidInputAndCancellationNeverDeliverPartialSuccess() throws {
        let buffer = try pcm()
        for relay in [RecordingStartupAudioBufferRelay(maximumBytes: 63),
                      RecordingStartupAudioBufferRelay(maximumBytes: 128)] {
            relay.append(buffer); relay.append(buffer); relay.append(buffer)
            XCTAssertNotNil(relay.activate { _ in XCTFail("Missing audio accepted") })
        }
        for frames: UInt32 in [0, 65537] {
            let relay = RecordingStartupAudioBufferRelay()
            relay.append(try pcm(frames: frames))
            XCTAssertNotNil(relay.activate { _ in XCTFail("Invalid buffer accepted") })
        }
        let cancelled = RecordingStartupAudioBufferRelay(maximumBuffers: 0, maximumBytes: 0)
        cancelled.cancel(); cancelled.append(buffer)
        XCTAssertNil(cancelled.activate { _ in XCTFail("Cancelled relay delivered") })
    }

    func testConfiguredTailTrimsBeforeCopyBudgetWithoutChangingOrder() throws {
        let relay = RecordingStartupAudioBufferRelay(maximumBufferedDuration: 0.002,
                                                     maximumBuffers: 2, maximumBytes: 128)
        for value: Float in [1, 2, 3, 4] {
            let buffer = try pcm(); buffer.floatChannelData![0][0] = value; relay.append(buffer)
        }
        var values: [Float] = []
        XCTAssertNil(relay.activate { values.append($0.floatChannelData![0][0]) })
        XCTAssertEqual(values, [3, 4])
    }

    func testReservationsBoundPreparationAndRetainCapacityAcrossAttemptReplacement() throws {
        for countLimit in [true, false] {
            let coordinator = AudioBufferWriteCoordinator(maximumOperations: countLimit ? 1 : 64,
                                                           maximumBytes: countLimit ? 1024 : 64)
            let old = coordinator.beginAttempt()
            var held: AudioBufferWriteCoordinator.Reservation? = try XCTUnwrap(coordinator.reserve(bytes: 64, attempt: old))
            var preparations = 1
            if coordinator.reserve(bytes: 1, attempt: old) != nil { preparations += 1 }
            XCTAssertEqual(preparations, 1)
            XCTAssertNotNil(old.error)
            let next = coordinator.beginAttempt()
            XCTAssertNil(coordinator.reserve(bytes: 64, attempt: next))
            XCTAssertNotNil(next.error)
            XCTAssertNotNil(held)
            held = nil
            coordinator.drain()
            let fresh = coordinator.beginAttempt()
            var accepted: AudioBufferWriteCoordinator.Reservation? = coordinator.reserve(bytes: 64, attempt: fresh)
            XCTAssertNotNil(accepted)
            accepted = nil; coordinator.drain()
            XCTAssertNil(coordinator.reserve(bytes: 1, attempt: old))
            XCTAssertNil(fresh.error)
        }
    }

    func testCancelledEnteredWriteKeepsPhysicalSlotAndOneSinkEffectUntilReturn() throws {
        let coordinator = AudioBufferWriteCoordinator(maximumOperations: 1)
        let old = coordinator.beginAttempt(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal(); coordinator.drain() }
        let sink = RecordingQueueSink()
        let reservation = try XCTUnwrap(coordinator.reserve(bytes: 64, attempt: old))
        reservation.submit { sink.append(1); started.signal(); release.wait() }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        old.cancel()
        let next = coordinator.beginAttempt()
        XCTAssertNil(coordinator.reserve(bytes: 64, attempt: next))
        XCTAssertEqual(sink.values, [1])
        release.signal(); coordinator.drain()
        let fresh = coordinator.beginAttempt()
        let final = try XCTUnwrap(coordinator.reserve(bytes: 64, attempt: fresh))
        final.submit { sink.append(2) }; final.submit { sink.append(99) }
        coordinator.drain()
        XCTAssertEqual(sink.values, [1, 2])
        XCTAssertNil(fresh.error)
    }

    func testThrowingWriterPreservesFirstFailureAndSkipsQueuedEffects() throws {
        let coordinator = AudioBufferWriteCoordinator()
        let attempt = coordinator.beginAttempt(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal(); coordinator.drain() }
        let sink = RecordingQueueSink()
        let first = try XCTUnwrap(coordinator.reserve(bytes: 16, attempt: attempt))
        first.submit { started.signal(); release.wait(); throw RecordingAudioQueueError.invalidBuffer }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let second = try XCTUnwrap(coordinator.reserve(bytes: 16, attempt: attempt))
        second.submit { sink.append(9) }
        release.signal(); coordinator.drain()
        attempt.fail(RecordingAudioQueueError.capacityExceeded)
        XCTAssertEqual(attempt.error as? RecordingAudioQueueError, .invalidBuffer)
        XCTAssertTrue(sink.values.isEmpty)
        XCTAssertNil(coordinator.reserve(bytes: 1, attempt: attempt))
    }

    func testLateOldFailureCannotPoisonFreshAttemptAndOldQueuedWriteDoesNotReplay() throws {
        let coordinator = AudioBufferWriteCoordinator()
        let old = coordinator.beginAttempt(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal(); coordinator.drain() }
        let sink = RecordingQueueSink()
        try XCTUnwrap(coordinator.reserve(bytes: 16, attempt: old)).submit {
            sink.append(1); started.signal(); release.wait(); throw RecordingAudioQueueError.invalidBuffer
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        try XCTUnwrap(coordinator.reserve(bytes: 16, attempt: old)).submit { sink.append(99) }
        let fresh = coordinator.beginAttempt()
        try XCTUnwrap(coordinator.reserve(bytes: 16, attempt: fresh)).submit { sink.append(2) }
        release.signal(); coordinator.drain()
        XCTAssertEqual(sink.values, [1, 2])
        XCTAssertNotNil(old.error); XCTAssertNil(fresh.error)
    }

    func testInvalidReservationAndPureConversionBoundsRefuseBeforeNativeAllocation() throws {
        for bytes in [0, -1, AudioBufferWriteCoordinator.maximumBufferBytes + 1] {
            let coordinator = AudioBufferWriteCoordinator(maximumOperations: 0, maximumBytes: 0)
            let attempt = coordinator.beginAttempt()
            XCTAssertNil(coordinator.reserve(bytes: bytes, attempt: attempt))
            XCTAssertEqual(attempt.error as? RecordingAudioQueueError, .invalidBuffer)
            coordinator.drain()
        }
        XCTAssertEqual(try AudioRecordingBufferConverter.outputCapacity(frameLength: 16, inputRate: 16000,
                                                                        outputRate: 16000, bytesPerFrame: 4), 272)
        for rate in [Double.nan, .infinity, 0, -1, .leastNonzeroMagnitude] {
            XCTAssertThrowsError(try AudioRecordingBufferConverter.outputCapacity(frameLength: 16, inputRate: rate,
                                                                                  outputRate: 16000, bytesPerFrame: 4))
        }
        XCTAssertThrowsError(try AudioRecordingBufferConverter.outputCapacity(frameLength: .max, inputRate: 1,
                                                                              outputRate: .infinity, bytesPerFrame: .max))
        let buffer = try pcm()
        let converter = AudioRecordingBufferConverter(targetFormat: buffer.format) // No AVAudioConverter constructed.
        XCTAssertEqual(try converter.reservationBytes(for: buffer), 272 * 8)
        buffer.frameLength = 0
        XCTAssertThrowsError(try converter.reservationBytes(for: buffer))
    }

    func testIncompleteFileReceiptAndRelayFailureUseExistingRealtimeErrorContract() async throws {
        let relay = RecordingStartupAudioBufferRelay(maximumBytes: 1)
        relay.append(try pcm())
        let error = try XCTUnwrap(relay.activate { _ in XCTFail("Truncated input") })
        let file = AudioFile(fileURL: URL(fileURLWithPath: "/private/synthetic-retained.wav"), duration: 1)
        let failure = IncompleteAudioRecording(file: file, cause: error)
        XCTAssertEqual(failure.file.fileURL, file.fileURL)
        XCTAssertTrue(failure.localizedDescription.contains("incomplete"))
        let upstream = RecordingQueueRealtimeSink()
        let pump = RealtimeAudioBufferPump(session: upstream)
        pump.failInput()
        do { try await pump.finishInput(); XCTFail("Missing startup prefix accepted") }
        catch { XCTAssertTrue(error is RealtimeAudioBufferError) }
        let cancels = await upstream.cancelCount()
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(RecordingAudioQueueError.capacityExceeded.localizedDescription.isEmpty)
    }
}

private final class RecordingQueueSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    func append(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
}
private actor RecordingQueueRealtimeSink: RealtimeTranscriptionSession {
    private var cancels = 0
    func start() async {}
    func append(_ buffer: AVAudioPCMBuffer) async {}
    func finish() async -> String { "unused" }
    func cancel() async { cancels += 1 }
    func cancelCount() -> Int { cancels }
}
