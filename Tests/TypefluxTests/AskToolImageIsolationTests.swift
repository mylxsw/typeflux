import AppKit
import SwiftUI
import XCTest
import TypefluxMediaProtocol
import TypefluxMediaRuntime
@testable import Typeflux

final class AskToolImageIsolationTests: XCTestCase {
    private func block(_ image: String? = nil) throws -> JSONValue {
        AskTypedContent.json(["type": "image", "mimeType": "image/jpeg", "data": try image ?? AskTypedContentTests.image()])
    }
    private func normalized() throws -> String {
        try XCTUnwrap(MediaDecoder.image(Data(base64Encoded: AskTypedContentTests.image())!, type: .jpeg).image)
    }

    func testNoSerializedProofOrUntrustedMarkerCanEnableProjection() async throws {
        let raw = try block()
        var original = AskExecutionOutcome(status: "ok", content: [raw])
        let url = try normalized()
        original.preparedImages = [AskToolPolicy.digest(raw.data): url]
        XCTAssertEqual(AskTypedContent.project(original).images, [url])
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        XCTAssertNil(wire["preparedImages"])
        wire["preparedImages"] = [AskToolPolicy.digest(raw.data): url]
        let decoded = try JSONDecoder().decode(AskExecutionOutcome.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(AskTypedContent.object(decoded.content![0]) as NSDictionary, AskTypedContent.object(original.content![0]) as NSDictionary)
        XCTAssertTrue(AskTypedContent.project(decoded).images.isEmpty)
        let prepared = await AskTypedContent.prepare(decoded, normalize: { try await AskToolImageNormalizer(worker: MediaWorker(timeout: 3)).normalize($0, type: $1) })
        XCTAssertEqual(AskTypedContent.project(prepared).images.count, 1)
        XCTAssertEqual(AskTypedContent.object(prepared.content![0]) as NSDictionary, AskTypedContent.object(original.content![0]) as NSDictionary)
        var changed = prepared; changed.content = [try block("aGVsbG8=")]
        XCTAssertTrue(AskTypedContent.project(changed).images.isEmpty)
    }

    func testNetworkUsesOnlyPreparedImagesAndPreservesRawLocalReceipt() async throws {
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 2, height: 2), type: .png).base64EncodedString()
        let raw = AskTypedContent.json(["type": "image", "mimeType": "image/png", "data": png, "_meta": ["retained": true]])
        let original = AskExecutionOutcome(status: "ok", content: [raw])
        let url = try normalized()
        let prepared = await AskTypedContent.prepare(original) { _, _ in url }
        var receipt = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "", isError: false, harness: .init(version: 1, outcome: prepared))
        let wire = receipt.forPeer(AskTypedContent.advertisement, enabled: [.typedContent])
        let block = AskTypedContent.object(wire.harness!.outcome!.content![0])
        XCTAssertEqual(block["mimeType"] as? String, "image/jpeg")
        XCTAssertEqual(block["data"] as? String, String(url.dropFirst("data:image/jpeg;base64,".count)))
        XCTAssertEqual((block["_meta"] as? [String: Bool])?["retained"], true)
        XCTAssertEqual(receipt.harness?.outcome?.content, [raw])
        XCTAssertTrue(wire.harness!.outcome!.preparedImages.isEmpty)
        receipt.harness?.outcome = original
        let unavailable = receipt.forPeer(AskTypedContent.advertisement, enabled: [.typedContent])
        XCTAssertTrue(unavailable.isError); XCTAssertNil(unavailable.image)
        XCTAssertEqual(unavailable.harness?.outcome?.truncated, true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(unavailable), as: UTF8.self).contains(png))
        var many = prepared; many.content = Array(repeating: raw, count: 10)
        receipt.harness?.outcome = many
        let bounded = receipt.forPeer(AskTypedContent.advertisement, enabled: [.typedContent])
        XCTAssertEqual(bounded.harness?.outcome?.content?.filter { AskTypedContent.object($0)["type"] as? String == "image" }.count, 4)
        XCTAssertEqual(bounded.harness?.outcome?.truncated, true)
    }

    func testFailureAndRevocationRetainReceiptWithoutRetryOrImageDisclosure() async throws {
        let calls = ImageIsolationCounter()
        let original = AskExecutionOutcome(status: "ok", content: [try block()])
        let prepared = await AskTypedContent.prepare(original) { _, _ in
            calls.increment(); throw MediaFailure.unavailable
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(AskTypedContent.object(prepared.content![0]) as NSDictionary, AskTypedContent.object(original.content![0]) as NSDictionary)
        XCTAssertEqual(prepared.safeStatus, .ok)
        XCTAssertTrue(AskTypedContent.project(prepared).incomplete)
        let output = AskTypedContent.withoutPreparedImages(.init(content: "ran", image: "ignored", outcome: original))
        let withheld = await AskTypedContent.prepare(try XCTUnwrap(output.outcome)) { _, _ in
            XCTFail("revocation must survive preparation"); throw MediaFailure.unavailable
        }
        var request = AskToolResultRequest(runId: "r", deviceId: "d", toolCallId: "c", content: "", isError: false)
        request.record(output)
        let reopened = try JSONDecoder().decode(AskToolResultRequest.self, from: JSONEncoder().encode(request))
        XCTAssertTrue(reopened.message(step: 1, now: Date()).retainedResultImages.isEmpty)
        XCTAssertEqual(withheld.content, original.content)
        XCTAssertNil(output.image)
        let network = reopened.forPeer(AskTypedContent.advertisement, enabled: [.typedContent])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(network), as: UTF8.self).contains("mimeType"))
        XCTAssertEqual(AskTypedContent.object(reopened.harness!.outcome!.content![0]) as NSDictionary, AskTypedContent.object(original.content![0]) as NSDictionary)
    }

    func testCountBytesMalformedAndCancellationBounds() async throws {
        let calls = ImageIsolationCounter()
        let raw = try block(), url = try normalized()
        let prepared = await AskTypedContent.prepare(.init(status: "ok", content: Array(repeating: raw, count: 10))) { _, _ in
            calls.increment(); return url
        }
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(prepared.content?.count, 10)
        // Duplicate originals share proof; the retained array still has original ordering.
        XCTAssertEqual(AskTypedContent.project(prepared).images.count, 4)
        XCTAssertTrue(AskTypedContent.project(prepared).incomplete)
        let invalid = await AskTypedContent.prepare(.init(status: "ok", content: [try block("@@@"), raw])) { _, _ in "untrusted" }
        XCTAssertTrue(invalid.preparedImages.isEmpty)
        XCTAssertNil(AskTypedContent.imageInput(["mimeType": "image/jpeg", "data": String(repeating: "x", count: 1_000_001)]))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await AskTypedContent.prepare(.init(status: "ok", content: [raw])) { _, _ in
                XCTFail("cancelled work must not dispatch"); return url
            }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.preparedImages.isEmpty)
        XCTAssertFalse(AskToolImageNormalizer.valid("data:image/jpeg;base64,@@@"))
        XCTAssertFalse(AskToolImageNormalizer.valid("data:image/jpeg;base64,aGVsbG8="))
        // A worker response may fit each frame but exceed the aggregate projection budget.
        let jpeg = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",", maxSplits: 1)[1])))
        let padded = Data(jpeg.dropLast(2)) + Data(repeating: 0, count: 800_000) + Data(jpeg.suffix(2))
        let large = "data:image/jpeg;base64," + padded.base64EncodedString()
        XCTAssertTrue(AskToolImageNormalizer.valid(large))
        let different = AskTypedContent.json(["type": "image", "mimeType": "image/jpeg", "data": try AskTypedContentTests.image(), "_meta": ["second": true]])
        let limited = await AskTypedContent.prepare(.init(status: "ok", content: [raw, different])) { _, _ in large }
        XCTAssertEqual(AskTypedContent.project(limited).images.count, 1)
        XCTAssertTrue(AskTypedContent.project(limited).incomplete)
        XCTAssertEqual(limited.content?.count, 2)
    }

    func testHistoryPreparationWindowAndOlderContentRemainAvailable() async throws {
        let raw = try block()
        let messages = (0..<15).map { i in
            AskMessage(id: "\(i)", role: "tool", text: "", createdAt: Date(), harness: .init(version: 1, outcome: .init(status: "ok", content: [raw])))
        }
        let prepared = await AskTypedContent.prepareHistory(messages, normalize: { try await AskToolImageNormalizer(worker: MediaWorker(timeout: 3)).normalize($0, type: $1) })
        XCTAssertEqual(prepared.filter { !$0.resultImages.isEmpty }.count, 8)
        XCTAssertTrue(prepared[0].resultImages.isEmpty)
        XCTAssertEqual(prepared[0].retainedResultImages.count, 1)
    }

    func testProtocolRequiresTypeAcknowledgementAndRejectsMIMEAndLargeDimensions() throws {
        var request = MediaRequest(operation: .normalizeImage)
        XCTAssertThrowsError(try request.validate())
        request.normalization = .jpeg
        try request.validate()
        let url = try normalized()
        var response = MediaResponse(id: request.id, items: [.init(image: url)])
        XCTAssertThrowsError(try response.validate(for: request))
        response.normalization = .jpeg
        try response.validate(for: request)
        response.normalization = .png
        XCTAssertThrowsError(try response.validate(for: request))
        let data = try XCTUnwrap(Data(base64Encoded: AskTypedContentTests.image()))
        XCTAssertThrowsError(try MediaDecoder.image(data, type: .png))
        XCTAssertThrowsError(try MediaDecoder.image(Data("truncated".utf8), type: .jpeg))
        let big = AskAttachmentFixture.image(width: 4097, height: 1)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: big).representation(using: .png, properties: [:]))
        XCTAssertThrowsError(try MediaDecoder.image(png, type: .png))
        XCTAssertThrowsError(try MediaDecoder.image(Data(repeating: 0, count: 10 * 1024 * 1024 + 1), type: .jpeg))
    }

    func testRealHelperNormalizationAndInputRefusal() async throws {
        let normalizer = AskToolImageNormalizer(worker: MediaWorker(timeout: 5))
        let data = try XCTUnwrap(Data(base64Encoded: AskTypedContentTests.image()))
        let url = try await normalizer.normalize(data, type: .jpeg)
        XCTAssertTrue(AskToolImageNormalizer.valid(url))
        for bytes in [Data(), Data(repeating: 0, count: 10 * 1024 * 1024 + 1)] {
            do { _ = try await normalizer.normalize(bytes, type: .jpeg); XCTFail("oversized/empty input") }
            catch { XCTAssertEqual(error as? MediaFailure, .tooLarge) }
        }
    }

    func testAdmissionCancellationAndNoReplacementUntilRetirement() async throws {
        let state = ImageIsolationCounter()
        let worker = MediaWorker(run: { request, cancelled in
            state.increment()
            while !cancelled() { Thread.sleep(forTimeInterval: 0.001) }
            return .init(termination: .cancelled, exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        })
        let normalizer = AskToolImageNormalizer(worker: worker)
        let data = Data([1])
        let first = Task { try await normalizer.normalize(data, type: .jpeg) }
        let second = Task { try await normalizer.normalize(data, type: .jpeg) }
        let deadline = Date().addingTimeInterval(5)
        while state.count < 2 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(state.count, 2)
        do { _ = try await normalizer.normalize(data, type: .jpeg); XCTFail("third must refuse") }
        catch { XCTAssertEqual(error as? MediaFailure, .unavailable) }
        first.cancel(); second.cancel()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("cancelled result") } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(worker.activeCount, 0)
    }

    func testSandboxKeepsProgramOutputWhenImageProjectionFails() async throws {
        let directory = try AskAttachmentFixture.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = try AskSecureDirectory.openRoot(directory.appendingPathComponent("workspace"))
        try workspace.createFile("out.png", data: Data([1, 2, 3]))
        let calls = ImageIsolationCounter()
        let image = await AskCodeSandbox.firstImage([("out.png", 3)], workspace: workspace) { _, _ in
            calls.increment(); throw MediaFailure.unavailable
        }
        XCTAssertNil(image.url); XCTAssertTrue(image.incomplete); XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try workspace.readFile("out.png", limit: 10), Data([1, 2, 3]))
        let execution = AskCodeSandbox.Execution(exitCode: 0, timedOut: false, stdout: "saved", stderr: "", changedFiles: [("out.png", 3)], image: nil, imageIncomplete: true)
        let report = AskCodeSandbox.report(execution, workspace: "fixture")
        XCTAssertTrue(report.contains("saved")); XCTAssertTrue(report.contains("Do not rerun"))
        let empty = await AskCodeSandbox.firstImage([], workspace: workspace)
        XCTAssertFalse(empty.incomplete)
        let url = try normalized()
        let success = await AskCodeSandbox.firstImage([("out.png", 3)], workspace: workspace) { _, _ in url }
        XCTAssertEqual(success.url, url); XCTAssertFalse(success.incomplete)
    }

    @MainActor func testCompletedPixelBudgetReleasesOnDisappearAndModelRelease() async throws {
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        let budget = AskToolPixelBudget(limit: 1600 * 1600 * 4)
        let url = "data:image/jpeg;base64," + (try AskTypedContentTests.image())
        var first: AskToolImageModel? = AskToolImageModel(budget: budget, decode: { _, _ in .init(images: [pixels], numbers: [], pages: 0) })
        let second = AskToolImageModel(budget: budget, decode: { _, _ in .init(images: [pixels], numbers: [], pages: 0) })
        await first?.load(url); XCTAssertNotNil(first?.image)
        await second.load(url); XCTAssertTrue(second.unavailable)
        first?.cancel()
        await second.load(url); XCTAssertNotNil(second.image)
        second.cancel()
        await first?.load(url); XCTAssertNotNil(first?.image)
        first = nil
        await second.load(url); XCTAssertNotNil(second.image)
        XCTAssertThrowsError(try budget.acquire(bytes: 0))
    }

    @MainActor func testToolImageUIRendersReadyAndUnavailableAndOwnsLifetime() async throws {
        let image = AskAttachmentFixture.image(width: 80, height: 40)
        let calls = ImageIsolationCounter()
        let model = AskToolImageModel(decode: { _, _ in calls.increment(); return .init(images: [image], numbers: [], pages: 0) })
        let url = "data:image/jpeg;base64," + (try AskTypedContentTests.image())
        let content = VStack {
            AskToolImageView(url: url, model: model)
            AskToolImageView(url: "invalid")
            AskRunOutputsView(outputs: .init(artifacts: [.init(id: "fixture", image: url, toolName: "mcp_fixture")]))
        }.padding().frame(width: 640, height: 480).background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(5)
        while model.image == nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.image)
        // Allow the real helper-backed card to settle before rendering the shared fixture.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(calls.count, 1, "Ready-state changes must not restart decoding")
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/typed-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("typed-images.png"))
        window.contentView = nil
        await Task.yield()
    }

    @MainActor func testViewOwnedPixelsRejectLateSelectionAndDisappear() async throws {
        let gate = ImageIsolationGate()
        let pixels = AskAttachmentFixture.image(width: 2, height: 2)
        let budget = AskToolPixelBudget(limit: 1600 * 1600 * 4)
        let model = AskToolImageModel(budget: budget, decode: { _, _ in
            await gate.wait(); return .init(images: [pixels], numbers: [], pages: 0)
        })
        let url = "data:image/jpeg;base64," + (try AskTypedContentTests.image())
        let task = Task { await model.load(url) }
        while !(await gate.started) { await Task.yield() }
        model.cancel()
        let replacement = AskToolImageModel(budget: budget, decode: { _, _ in
            XCTFail("Uncooperative old work still owns its reservation"); return .init(images: [], numbers: [], pages: 0)
        })
        await replacement.load(url); XCTAssertTrue(replacement.unavailable)
        await gate.release(); await task.value
        XCTAssertNil(model.image)
        let ready = AskToolImageModel(decode: { _, _ in .init(images: [pixels], numbers: [], pages: 0) })
        await ready.load(url); XCTAssertNotNil(ready.image)
        ready.cancel(); XCTAssertNil(ready.image)
        await ready.load("invalid"); XCTAssertTrue(ready.unavailable)
        let failed = AskToolImageModel(decode: { _, _ in throw MediaFailure.unavailable })
        await failed.load(url); XCTAssertTrue(failed.unavailable)
        let empty = AskToolImageModel(decode: { _, _ in .init(images: [], numbers: [], pages: 0) })
        await empty.load(url); XCTAssertTrue(empty.unavailable)
    }
}

private final class ImageIsolationCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
private actor ImageIsolationGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
