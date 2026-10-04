import AVFoundation
import XCTest

@testable import Typeflux

final class RecordingAudioReadinessTests: XCTestCase {
    func testAudioBeforeSetupIsRememberedAndDeliveredOnce() {
        let readiness = RecordingAudioReadiness()
        readiness.receiveAudio()
        var calls = 0
        readiness.whenReady { calls += 1 }
        readiness.receiveAudio()
        readiness.whenReady { calls += 1 }
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testSetupWaitsForAudioAndCallbackCanReenter() {
        let readiness = RecordingAudioReadiness()
        var calls = 0
        readiness.whenReady {
            calls += 1
            XCTAssertTrue(readiness.isReady)
            readiness.cancel()
        }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(readiness.isReady)
        readiness.receiveAudio()
        readiness.receiveAudio()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(readiness.isReady)
    }

    func testCancellationDiscardsPendingAndFutureCallbacks() {
        let readiness = RecordingAudioReadiness()
        readiness.whenReady { XCTFail("Cancelled recording must not become ready") }
        readiness.cancel()
        readiness.receiveAudio()
        readiness.whenReady { XCTFail("Late setup must not revive a cancelled recording") }
        XCTAssertFalse(readiness.isReady)
    }

    func testConcurrentAudioAndSetupDeliverOnce() {
        let readiness = RecordingAudioReadiness()
        let lock = NSLock()
        var calls = 0
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) {
                readiness.receiveAudio()
            } else {
                readiness.whenReady { lock.withLock { calls += 1 } }
            }
        }
        XCTAssertEqual(calls, 1)
    }

    func testDigitalSilenceIsReadyWhenSignalIsNotRequired() throws {
        let readiness = RecordingAudioReadiness()
        var calls = 0
        readiness.whenReady { calls += 1 }
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testEmptyBufferIsIgnored() throws {
        let readiness = RecordingAudioReadiness()
        readiness.receiveAudio(try Self.buffer(amplitude: 0.2, frames: 0))
        XCTAssertFalse(readiness.isReady)
    }

    func testBluetoothInputWaitsForFirstSound() throws {
        let readiness = RecordingAudioReadiness(signalWaitTimeout: 60)
        var calls = 0
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        readiness.whenReady(requiringSignal: true) { calls += 1 }
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(readiness.isReady)
        // Quiet speech is still sound.
        readiness.receiveAudio(try Self.buffer(amplitude: 0.000_1))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(readiness.isReady)
        readiness.receiveAudio(try Self.buffer(amplitude: 0.5))
        XCTAssertEqual(calls, 1)
    }

    func testSoundBeforeSetupSatisfiesSignalRequirement() throws {
        let readiness = RecordingAudioReadiness(signalWaitTimeout: 60)
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        readiness.receiveAudio(try Self.buffer(amplitude: 0.3))
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        var calls = 0
        readiness.whenReady(requiringSignal: true) { calls += 1 }
        XCTAssertEqual(calls, 1)
    }

    func testSilentBluetoothInputBecomesReadyAfterTimeout() throws {
        let readiness = RecordingAudioReadiness(signalWaitTimeout: 0.05)
        let ready = expectation(description: "ready after timeout")
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        readiness.whenReady(requiringSignal: true) { ready.fulfill() }
        XCTAssertFalse(readiness.isReady)
        wait(for: [ready], timeout: 2)
        XCTAssertTrue(readiness.isReady)
    }

    func testTimeoutStillWaitsForTheFirstBuffer() throws {
        let readiness = RecordingAudioReadiness(signalWaitTimeout: 0.01)
        var calls = 0
        readiness.whenReady(requiringSignal: true) { calls += 1 }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(calls, 0)
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        XCTAssertEqual(calls, 1)
    }

    func testCancellationSuppressesTimeoutCallback() throws {
        let readiness = RecordingAudioReadiness(signalWaitTimeout: 0.01)
        readiness.receiveAudio(try Self.buffer(amplitude: 0))
        readiness.whenReady(requiringSignal: true) { XCTFail("Cancelled recording must not become ready") }
        readiness.cancel()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(readiness.isReady)
    }

    private static func buffer(amplitude: Float, frames: AVAudioFrameCount = 160) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = amplitude }
        return buffer
    }
}
