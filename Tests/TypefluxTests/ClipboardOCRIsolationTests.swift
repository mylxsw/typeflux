import AppKit
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

private final class OCRActions: ClipboardContentActing {
    var read: () async throws -> String? = { "text" }
    var calls = 0
    func recognizeText(in imageURL: URL) async throws -> String? { calls += 1; return try await read() }
    func writeToPasteboard(_ entry: ClipboardEntry, asPlainText: Bool, image: AskWorkflowImage.Clipboard?) -> Bool { XCTFail("OCR used image write"); return false }
    func sendPasteShortcut() { XCTFail("OCR sent paste") }
    func revealInFinder(_ urls: [URL]) {}
    func saveToDownloads(_ url: URL) -> URL? { nil }
}

private final class OCRBlocking: @unchecked Sendable {
    let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func run() throws -> ManagedProcess.Result { lock.withLock { calls += 1 }; gate.wait(); throw MediaFailure.unavailable }
}

@MainActor final class ClipboardOCRIsolationTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Pending OCR did not finish")
    }
    private func worker() throws -> MediaWorker {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/clipboard-ocr-validation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return MediaWorker(timeout: 30, run: { request, cancelled in
            var request = request; request.environment["LLVM_PROFILE_FILE"] = folder.appendingPathComponent("helper-%p.profraw").path
            return try ManagedProcess().runBlocking(request, isCancelled: cancelled)
        })
    }
    func testProtocolRejectsMixedIdentityExcessLinesBytesAndControls() throws {
        let request = MediaRequest(operation: .clipboardOCR)
        var response = MediaResponse(id: request.id); response.ocr = .init(lines: [" one ", "two"])
        try response.validate(for: request); XCTAssertEqual(response.ocr?.text, "one \ntwo")
        XCTAssertNil(MediaOCRResult(lines: [" \n "]).text)
        let mutations: [(inout MediaResponse) -> Void] = [
            { $0.id = UUID() }, { $0.version = 2 }, { $0.ocr = nil }, { $0.items = [.init(text: "x")] },
            { $0.failure = .unavailable }, { $0.clipboard = .init(pages: 1) }, { $0.preview = .init(rasters: []) },
            { $0.normalization = .png }, { $0.generatedImage = .init(mediaType: "image/png", width: 1, height: 1) }
        ]
        for change in mutations { var value = response; change(&value); XCTAssertThrowsError(try value.validate(for: request)) }
        for lines in [Array(repeating: "", count: 1025), [String(repeating: "x", count: 16385)], ["x\0"], Array(repeating: String(repeating: "x", count: 16384), count: 16)] {
            XCTAssertThrowsError(try MediaOCRResult(lines: lines).validate())
        }
        let other = MediaRequest(id: request.id, operation: .image)
        XCTAssertThrowsError(try response.validate(for: other))
    }

    func testChildValidatesImageBeforeEngineAndRejectsExcessOutput() throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input"), request = MediaRequest(operation: .clipboardOCR)
        try ClipboardTestSupport.imageData(width: 100, height: 30).write(to: input)
        let value = try MediaOCRDecoder.decode(request, directory: root) { image in
            XCTAssertEqual(image.width, 100); return ["Local text"]
        }
        XCTAssertEqual(value.ocr?.text, "Local text")
        XCTAssertThrowsError(try MediaOCRDecoder.decode(request, directory: root) { _ in throw MediaFailure.unavailable })
        XCTAssertThrowsError(try MediaOCRDecoder.decode(request, directory: root) { _ in Array(repeating: "x", count: 1025) })
        XCTAssertThrowsError(try MediaOCRDecoder.decode(.init(operation: .image), directory: root))
        for data in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: MediaOCRResult.inputBytes + 1)] {
            try data.write(to: input)
            XCTAssertThrowsError(try MediaOCRDecoder.decode(request, directory: root) { _ in XCTFail("Invalid input reached OCR"); return [] })
        }
    }

    func testRealHelperTextBlankMalformedAndRereadAreDistinct() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.png"), worker = try worker()
        let recognizer = ClipboardTextRecognizer(worker: worker)
        try ClipboardTestSupport.imageData(width: 900, height: 240, text: "TYPEFLUX").write(to: file)
        let text = try await recognizer.recognize(file); XCTAssertTrue(text?.uppercased().contains("TYPEFLUX") == true)
        try ClipboardTestSupport.imageData(width: 200, height: 200).write(to: file)
        let empty = try await recognizer.recognize(file); XCTAssertNil(empty)
        try Data([1, 2]).write(to: file)
        do { _ = try await recognizer.recognize(file); XCTFail("Malformed became empty") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2]))
        await worker.shutdown()
    }

    func testSourceChangeAndOversizeRefuseWithoutPublishingText() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png"); try Data([1]).write(to: file)
        let worker = MediaWorker(run: { request, _ in
            let input = try JSONDecoder().decode(MediaRequest.self, from: request.stdin!)
            var response = MediaResponse(id: input.id); response.ocr = .init(lines: ["stale"])
            try Data([2, 3]).write(to: file, options: .atomic)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        do { _ = try await ClipboardTextRecognizer(worker: worker).recognize(file); XCTFail("Changed file accepted") } catch {}
        try Data(repeating: 0, count: MediaOCRResult.inputBytes + 1).write(to: file)
        do { _ = try await ClipboardTextRecognizer(worker: worker).recognize(file); XCTFail("Oversize accepted") } catch {}
        let task = Task { try await ClipboardTextRecognizer(worker: worker).recognize(file) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch {}
    }

    func testCancelledUncooperativeWorkRetainsBothAdmissions() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input"); try Data([1]).write(to: file)
        let block = OCRBlocking(), worker = MediaWorker(run: { _, _ in try block.run() })
        let recognizer = ClipboardTextRecognizer(worker: worker)
        let first = Task { try await recognizer.recognize(file) }, second = Task { try await recognizer.recognize(file) }
        try await wait { block.count == 2 }; first.cancel(); second.cancel()
        do { _ = try await recognizer.recognize(file); XCTFail("Cancelled tasks released admission") } catch {}
        XCTAssertEqual(block.count, 2); block.gate.signal(); block.gate.signal()
        _ = await first.result; _ = await second.result
        await worker.shutdown()
    }

    func testExplicitCopyCommitsOnceAndEmptyDiffersFromFailure() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image"); try Data([1]).write(to: file)
        for mode in 0...3 {
            let action = ClipboardContentAction(), actions = OCRActions()
            var commits = 0, failures = 0, received: String?
            actions.read = { if mode == 2 { throw MediaFailure.unavailable }; return mode == 0 ? "text" : mode == 3 ? String(repeating: "x", count: 16385) : nil }
            XCTAssertTrue(action.startText(url: file, actions: actions, authorized: { true }, commit: { received = $0; commits += 1 }, failed: { failures += 1 }))
            try await wait { !action.isRunning }
            XCTAssertEqual(commits, mode < 2 ? 1 : 0); XCTAssertEqual(failures, mode < 2 ? 0 : 1)
            XCTAssertEqual(received, mode == 0 ? "text" : nil); XCTAssertEqual(actions.calls, 1)
        }
    }

    func testRevocationDeletionHideSourceMutationAndShutdownFenceCopy() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image"); try Data([1]).write(to: file)
        for mode in 0...4 {
            let action = ClipboardContentAction(), actions = OCRActions()
            var allowed = true, writes = 0
            actions.read = {
                switch mode {
                case 0: allowed = false
                case 1: NotificationCenter.default.post(name: .authDidLogout, object: nil)
                case 2: action.cancelPreparation()
                case 3: try Data([2, 3]).write(to: file, options: .atomic)
                default: action.preventNewWork()
                }
                return "late"
            }
            action.startText(url: file, actions: actions, authorized: { allowed }, commit: { _ in writes += 1 }, failed: {})
            try await wait { !action.isRunning }; XCTAssertEqual(writes, 0)
        }
    }

    func testDuplicateAndOwnerReleaseKeepLateOCRFromCommitting() async throws {
        let root = try AskAttachmentFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image"); try Data([1]).write(to: file)
        var action: ClipboardContentAction? = ClipboardContentAction()
        let actions = OCRActions(); var resume: CheckedContinuation<String?, Never>?, writes = 0
        actions.read = { await withCheckedContinuation { resume = $0 } }
        action?.startText(url: file, actions: actions, authorized: { true }, commit: { _ in writes += 1 }, failed: {})
        try await wait { resume != nil }; action?.cancel()
        XCTAssertFalse(action!.startText(url: file, actions: actions, authorized: { true }, commit: { _ in writes += 1 }, failed: {}))
        weak var owner = action; action = nil; XCTAssertNil(owner)
        resume?.resume(returning: "late"); try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes, 0); XCTAssertEqual(actions.calls, 1)
    }
}
