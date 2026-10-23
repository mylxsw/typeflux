import AppKit
import PDFKit
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

final class MediaWorkerTests: XCTestCase {
    func testBundledAndSwiftPMHelperLocations() {
        XCTAssertEqual(MediaWorker.helperURL(appExecutable: URL(fileURLWithPath: "/build/Typeflux")).path,
                       "/build/TypefluxMediaHelper")
        XCTAssertEqual(MediaWorker.helperURL(appExecutable: URL(fileURLWithPath: "/App.app/Contents/MacOS/Typeflux")).path,
                       "/App.app/Contents/Helpers/TypefluxMediaHelper")
    }

    private func result(_ response: MediaResponse) throws -> ManagedProcess.Result {
        .init(termination: .exited(0), exitCode: 0,
              stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
    }

    private func request(_ process: ManagedProcess.Request) throws -> MediaRequest {
        try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
    }

    func testCopiedInputIsPrivateAndRemovedOnlyAfterConfirmedCollection() throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { process, _ in
            process.onStarted?()
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            XCTAssertEqual(fcntl(process.directoryDescriptor, F_GETPATH, &path), 0)
            let directory = URL(fileURLWithPath: String(cString: path))
            state.directory = directory
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("input")), Data("private".utf8))
            let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
            state.reaped = process.onReaped
            return .init(termination: .timedOut, exitCode: 137, stdout: "", stderr: "private error", outputTruncated: false)
        })
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data("private".utf8))))
        XCTAssertEqual(worker.activeCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(state.directory).path))
        state.reaped?()
        let deadline = Date().addingTimeInterval(2)
        while worker.activeCount > 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertEqual(worker.activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(state.directory).path))
    }

    func testProtocolIdentityFailureAndCooldownNeverReplay() throws {
        let state = MediaTestState()
        let worker = MediaWorker(uptime: { state.time }, run: { process, _ in
            state.calls += 1
            return try self.result(MediaResponse(id: UUID(), failure: .unreadable))
        })
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data())))
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data())))
        XCTAssertEqual(state.calls, 1)
        state.time = 2
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data())))
        XCTAssertEqual(state.calls, 2)
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testMalformedInputFailureDoesNotPoisonOtherAttachments() throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { process, _ in
            state.calls += 1
            let request = try self.request(process)
            if state.calls == 1 { return try self.result(MediaResponse(id: request.id, failure: .unreadable)) }
            return try self.result(MediaResponse(id: request.id, items: [.init(text: "kept", pages: 1)]))
        })
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        XCTAssertEqual(try worker.decode(.pdf, input: .data(Data())).items.first?.text, "kept")
        XCTAssertEqual(state.calls, 2)
    }

    func testOversizedDataFileMissingFileAndFIFORefusedBeforeSpawn() throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { _, _ in state.calls += 1; throw MediaFailure.unavailable })
        let directory = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(MediaLimits.inputBytes + 1)); try handle.close()
        XCTAssertThrowsError(try worker.decode(.image, input: .file(file)))
        XCTAssertThrowsError(try worker.decode(.pdf, input: .file(directory.appendingPathComponent("missing"))))
        XCTAssertThrowsError(try worker.decode(.pdf, input: .file(directory)))
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .file(fifo)))
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data(count: MediaLimits.inputBytes + 1))))
        XCTAssertEqual(state.calls, 0)
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testTwoRetainedChildrenBoundAdmissionAndShutdownFences() async throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { process, _ in
            process.onStarted?()
            state.callbacks.append(process.onReaped!)
            let request = try self.request(process)
            return try self.result(MediaResponse(id: request.id, items: [.init(text: "ok", pages: 1)]))
        })
        _ = try worker.decode(.pdf, input: .data(Data()))
        _ = try worker.decode(.pdf, input: .data(Data()))
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        XCTAssertEqual(worker.activeCount, 2)
        worker.preventNewWork()
        state.callbacks.forEach { $0() }
        await worker.shutdown()
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data())))
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testCancellationBeforeAndAfterDispatchRejectsLateResult() throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { process, _ in
            state.calls += 1; state.cancelled = true
            return try self.result(MediaResponse(id: try self.request(process).id, items: [.init(text: "late", pages: 1)]))
        })
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data()), isCancelled: { true }))
        XCTAssertEqual(state.calls, 0)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data()), isCancelled: { state.cancelled }))
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testRealHelperImagePDFMalformedAndCrashHangFixtures() async throws {
        let directory = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/media-validation")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        let worker = MediaWorker(run: { process, cancelled in
            var process = process
            process.environment["LLVM_PROFILE_FILE"] = profiles.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(process, isCancelled: cancelled)
        })
        let image = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 30, height: 20), type: .png)
        let file = directory.appendingPathComponent("image")
        try image.write(to: file)
        XCTAssertEqual(try worker.decode(.image, input: .file(file)).items.count, 1)
        XCTAssertThrowsError(try worker.decode(.pdf, input: .data(Data("broken".utf8))))
        XCTAssertThrowsError(try worker.decode(.image, input: .data(image.prefix(20))))
        for script in ["kill -KILL $$", "trap '' TERM; while :; do sleep 1; done"] {
            let fixture = directory.appendingPathComponent(UUID().uuidString)
            try ("#!/bin/sh\n" + script + "\n").write(to: fixture, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
            let fault = MediaWorker(executable: fixture, timeout: 0.1)
            let start = ContinuousClock.now
            XCTAssertThrowsError(try fault.decode(.pdf, input: .data(Data())))
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await fault.shutdown()
            XCTAssertEqual(fault.activeCount, 0)
        }
        await worker.shutdown()
    }

    func testShutdownCancelsRunningChildAndRejectsNewWork() async throws {
        let state = MediaTestState()
        let worker = MediaWorker(run: { _, cancelled in
            state.entered.signal()
            while !cancelled() { Thread.sleep(forTimeInterval: 0.001) }
            throw CancellationError()
        })
        let task = Task.detached { try worker.decode(.image, input: .data(Data())) }
        XCTAssertEqual(state.entered.wait(timeout: .now() + 2), .success)
        await worker.shutdown()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(worker.activeCount, 0)
        XCTAssertThrowsError(try worker.decode(.image, input: .data(Data())))
    }
}

private final class MediaTestState: @unchecked Sendable {
    var directory: URL?
    var reaped: (@Sendable () -> Void)?
    var callbacks: [@Sendable () -> Void] = []
    var calls = 0
    var time: TimeInterval = 0
    var cancelled = false
    let entered = DispatchSemaphore(value: 0)
}


extension MediaWorkerTests {
    func testQueueBackpressureDoesNotConsumeDecoderRecoveryBudget() throws {
        let worker = MediaWorker(run: { _, _ in throw MediaWorkAdmissionBusy.busy })
        for _ in 0..<10 {
            XCTAssertThrowsError(try worker.decode(.image, input: .data(Data([1])))) {
                XCTAssertEqual($0 as? MediaFailure, .unavailable)
            }
            XCTAssertTrue(worker.permits(worker.authorization()))
        }
        XCTAssertEqual(worker.activeCount, 0)
    }
}


extension MediaWorkerTests {
    func testCancelledRemoteWorkDoesNotConsumeDecoderRecoveryBudget() throws {
        let worker = MediaWorker(run: { _, _ in throw CancellationError() })
        for _ in 0..<10 {
            XCTAssertThrowsError(try worker.decode(.image, input: .data(Data([1])))) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertTrue(worker.permits(worker.authorization()))
        }
        XCTAssertEqual(worker.activeCount, 0)
    }
}
