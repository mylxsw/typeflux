import AppKit
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private struct ScrollFixedRegistration: ScrollFrameRegistering {
    var shifts: [Int]
    var fails = false
    func verticalShifts(from previous: CGImage, to current: CGImage) async throws -> [Int] {
        if fails { throw MediaFailure.unavailable }
        return shifts
    }
}

final class ScrollRegistrationIsolationTests: XCTestCase {
    private func request() -> MediaRequest {
        var request = MediaRequest(operation: .registerFrames)
        request.registration = .init(width: 40, height: 30)
        return request
    }

    func testProtocolBoundsIdentityAndMixedResults() throws {
        var request = request(); try request.validate()
        var result = MediaResponse(id: request.id); result.registration = .init(translationY: 12)
        try result.validate(for: request)
        result.registration = .init(translationY: nil); try result.validate(for: request)
        for value in [Double.nan, .infinity, 31, -31] {
            result.registration = .init(translationY: value)
            XCTAssertThrowsError(try result.validate(for: request))
        }
        result.registration = .init(translationY: 0); result.geometry = .init(boxes: [])
        XCTAssertThrowsError(try result.validate(for: request)); result.geometry = nil
        result.failure = .unavailable; XCTAssertThrowsError(try result.validate(for: request)); result.failure = nil
        result.id = UUID(); XCTAssertThrowsError(try result.validate(for: request))
        request.operation = .image; XCTAssertThrowsError(try request.validate())
        XCTAssertThrowsError(try MediaRequest(operation: .registerFrames).validate())
        for pair in [(0, 1), (1, 0), (Int.max, 1), (16385, 1), (4000, 4001)] {
            XCTAssertThrowsError(try MediaRegistrationInput(width: pair.0, height: pair.1).validate())
        }
        try MediaRegistrationInput(width: 4000, height: 4000).validate()
        var unrelated = MediaRequest(operation: .textGeometry); unrelated.textInput = .init(width: 20, height: 20)
        result.id = unrelated.id; XCTAssertThrowsError(try result.validate(for: unrelated))
    }

    func testDecoderChecksBothFramesBeforeCallingNativeAdapter() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let request = request(), file = root.appendingPathComponent("input")
        try Data(repeating: 255, count: 40 * 30 * 8).write(to: file)
        let result = try MediaRegistrationDecoder.decode(request, directory: root, register: { before, after in
            XCTAssertEqual(before.width, 40); XCTAssertEqual(after.height, 30); return -12.5
        })
        XCTAssertEqual(result.registration?.translationY, -12.5)
        XCTAssertThrowsError(try MediaRegistrationDecoder.decode(request, directory: root, register: { _, _ in throw MediaFailure.unavailable }))
        for count in [0, 4799, 9599, 9601] {
            try Data(repeating: 0, count: count).write(to: file)
            XCTAssertThrowsError(try MediaRegistrationDecoder.decode(request, directory: root, register: { _, _ in
                XCTFail("Malformed pair reached native adapter"); return 0
            }))
        }
        XCTAssertThrowsError(try MediaRegistrationDecoder.decode(MediaRequest(operation: .image), directory: root))
    }

    func testOverflowCandidatesCannotTrapPureChecks() {
        for value in [CGFloat.nan, .infinity, -.infinity, CGFloat.greatestFiniteMagnitude, CGFloat(Int.max), -16385] {
            XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: value), [])
        }
        XCTAssertEqual(VisionScrollOffsetEstimator.shifts(translationY: -12.6), [-13, 13])
        let page = ScrollCaptureFixtures.page()
        let frame = page.frame(offset: 0, scrollingHeight: 250)
        for value in [Int.min, Int.max, 250, -250] {
            XCTAssertNil(ScrollStitcher.evaluate(shift: value, previous: frame.signature,
                current: frame.signature, middle: 0..<250))
        }
    }

    func testRealChildReturnsCandidatesAndPureStitcherStillChecksThem() async throws {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/scroll-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let worker = MediaWorker(timeout: 3, run: { request, cancelled in
            var request = request
            request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
        let page = ScrollCaptureFixtures.page(width: 200, height: 900)
        let before = page.frame(offset: 0, scrollingHeight: 400), after = page.frame(offset: 120, scrollingHeight: 400)
        let detector = VisionScrollOffsetEstimator(worker: worker)
        let candidates = try await detector.verticalShifts(from: before.image, to: after.image)
        XCTAssertTrue(candidates.contains(120))
        var stitcher = DirectionalScrollStitcher()
        let initial = try await stitcher.addPreparingOffsets(before, registration: detector)
        let joined = try await stitcher.addPreparingOffsets(after, registration: detector)
        XCTAssertEqual(initial, .started); XCTAssertEqual(joined, .appended(rows: 120, suspicious: false))
        XCTAssertEqual(stitcher.height, 520)
        do { _ = try await detector.verticalShifts(from: before.image, to: ScrollCaptureFixtures.solid(width: 1, height: 1, gray: 255)); XCTFail() } catch {}
        await worker.shutdown()
        do { _ = try await detector.verticalShifts(from: before.image, to: after.image); XCTFail() } catch {}
    }

    func testFailureAndMaliciousCandidatesPreserveAxisUndoAndRowValidation() async throws {
        let page = ScrollCaptureFixtures.page(width: 200, height: 900)
        for horizontal in [false, true] {
            func frame(_ offset: Int) -> ScrollFrame {
                let image = page.frameImage(offset: offset, scrollingHeight: 400)
                return ScrollFrame(image: horizontal ? ScrollCaptureAxis.horizontal.orient(image)! : image)!
            }
            var stitcher = DirectionalScrollStitcher()
            _ = try await stitcher.addPreparingOffsets(frame(0), registration: nil)
            let joined = try await stitcher.addPreparingOffsets(frame(120), registration: ScrollFixedRegistration(shifts: [Int.min, Int.max]))
            XCTAssertEqual(joined, .appended(rows: 120, suspicious: false))
            XCTAssertEqual(stitcher.axis, horizontal ? .horizontal : .vertical)
            let next = try await stitcher.addPreparingOffsets(frame(240), registration: ScrollFixedRegistration(shifts: [], fails: true))
            XCTAssertEqual(next, .appended(rows: 120, suspicious: false))
            XCTAssertTrue(stitcher.removeLastSegment())
            let afterUndo = try await stitcher.addPreparingOffsets(frame(240), registration: ScrollFixedRegistration(shifts: [40]))
            XCTAssertEqual(afterUndo, .appended(rows: 120, suspicious: false))
        }
    }

    func testCancellationAndTwoAdmissionsRemainOwnedUntilUncooperativeWorkReturns() async throws {
        let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
        let worker = MediaWorker(run: { request, _ in
            entered.signal(); gate.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
            var response = MediaResponse(id: request.id); response.registration = .init(translationY: 0)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let image = ScrollCaptureFixtures.solid(width: 200, height: 200, gray: 255)
        let detector = VisionScrollOffsetEstimator(worker: worker)
        let first = Task { try await detector.verticalShifts(from: image, to: image) }
        let second = Task { try await detector.verticalShifts(from: image, to: image) }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        first.cancel(); second.cancel()
        do { _ = try await detector.verticalShifts(from: image, to: image); XCTFail("Cancelled work still occupies both slots") } catch {}
        gate.signal(); gate.signal()
        for task in [first, second] { do { _ = try await task.value; XCTFail() } catch {} }
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testRegistrationChildCrashAndHangAreBoundedWithoutReplay() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = ScrollCaptureFixtures.solid(width: 200, height: 200, gray: 255)
        for script in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let file = root.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + script + "\n").write(to: file, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let worker = MediaWorker(executable: file, timeout: 0.1)
            let start = ContinuousClock.now
            do { _ = try await VisionScrollOffsetEstimator(worker: worker).verticalShifts(from: image, to: image); XCTFail() } catch {}
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await worker.shutdown(); XCTAssertEqual(worker.activeCount, 0)
        }
    }

    @MainActor func testActualPanelHideCancelsOnceAndOrdinaryDismissDoesNotCancel() {
        let presenter = ScrollCaptureOverlayController(primaryDisplayHeight: { 800 })
        let region = ScrollCaptureRegion(displayID: 1, displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            scale: 1, rect: CGRect(x: 200, y: 200, width: 200, height: 200))
        var cancelled = 0
        let actions = ScrollCaptureActions(togglePause: {}, undo: {}, cancel: { cancelled += 1; presenter.dismiss() },
            finish: {}, openAccessibilitySettings: {})
        presenter.present(region, actions: actions)
        presenter.barPanel?.orderOut(nil)
        XCTAssertEqual(cancelled, 1); XCTAssertFalse(presenter.isPresented)
        presenter.present(region, actions: actions); presenter.dismiss()
        XCTAssertEqual(cancelled, 1)
    }

    func testFrameInboxCoalescesAndClosesWithoutReplacementTasks() {
        let inbox = ScrollFrameInbox()
        let first = ScrollCaptureFixtures.solid(width: 20, height: 20, gray: 255)
        let last = ScrollCaptureFixtures.solid(width: 21, height: 20, gray: 255)
        XCTAssertTrue(inbox.offer(first))
        for _ in 0..<1000 { XCTAssertFalse(inbox.offer(last)) }
        XCTAssertTrue(inbox.take() === last); XCTAssertNil(inbox.take())
        XCTAssertTrue(inbox.offer(first)); inbox.close()
        XCTAssertNil(inbox.take()); XCTAssertFalse(inbox.offer(last))
        let oversized = ScrollCaptureFixtures.solid(width: 16385, height: 1, gray: 255)
        XCTAssertFalse(ScrollFrameInbox().offer(oversized))
        let failure = ScrollFrameInbox(); XCTAssertTrue(failure.offer(first))
        XCTAssertTrue(failure.fail()); XCTAssertFalse(failure.fail()); XCTAssertNil(failure.take())
    }
}
