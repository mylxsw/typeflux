import AppKit
import Darwin
import TypefluxMediaProtocol
import TypefluxMediaRuntime
import XCTest
@testable import Typeflux

@MainActor
final class AskGeneratedImageIsolationTests: XCTestCase {
    let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-isolation-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func journal(_ call: String = "call") throws -> AskImageGenerationRetention {
        try .init(rootURL: root, scope: scope, callId: call, metadata: Data("request metadata".utf8))
    }
    func load(_ journal: AskImageGenerationRetention, call: String = "call") throws -> [String: Data] {
        try AskImageGenerationRetention.load(rootURL: root, id: journal.id, scope: scope, callId: call)
    }

    func testPrivateJournalReopensAndRefusesDuplicateCallAndWrongOwner() throws {
        let journal = try journal()
        try journal.response(Data("raw response".utf8))
        try journal.downloaded(Data("original image".utf8))
        XCTAssertEqual(try load(journal)["download-0"], Data("original image".utf8))
        XCTAssertEqual(try load(journal)["response.json"], Data("raw response".utf8))
        XCTAssertThrowsError(try self.journal())
        XCTAssertThrowsError(try AskImageGenerationRetention.load(rootURL: root, id: journal.id,
            scope: .init(ownerId: "other", conversationId: scope.conversationId, runId: scope.runId), callId: "call"))
        XCTAssertThrowsError(try AskImageGenerationRetention.load(rootURL: root, id: "../bad", scope: scope, callId: "call"))
        XCTAssertThrowsError(try AskImageGenerationRetention.load(rootURL: root, id: journal.id, scope: scope, callId: "other"))
        let directory = root.appendingPathComponent(journal.id)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("response.json").path)[.posixPermissions] as? Int, 0o600)
        try AskImageGenerationRetention.delete(rootURL: root, ownerId: "other", conversationId: scope.conversationId)
        XCTAssertNotNil(try load(journal)["response.json"])
        try AskImageGenerationRetention.delete(rootURL: root, ownerId: scope.ownerId, conversationId: scope.conversationId)
        XCTAssertThrowsError(try load(journal))
        XCTAssertThrowsError(try journal.response(Data()), "Deletion during a suspended request must not recreate its directory")
    }

    func testRetentionBudgetsRefuseBeforeDispatchAndNeverEvictPendingOutput() throws {
        let journal = try journal()
        try journal.response(Data("keep".utf8))
        for index in 1..<8 { _ = try self.journal("call-\(index)") }
        XCTAssertThrowsError(try self.journal("overflow"))
        XCTAssertEqual(try load(journal)["response.json"], Data("keep".utf8))
        XCTAssertThrowsError(try journal.response(Data(count: AskImageGenerationService.maximumResponseBytes + 1)))
        XCTAssertThrowsError(try journal.downloaded(Data(count: AskArtifactStore.maximumFileBytes + 1)))
        try journal.downloaded(Data(count: AskArtifactStore.maximumFileBytes))
        try journal.downloaded(Data(count: AskArtifactStore.maximumFileBytes))
        XCTAssertThrowsError(try journal.downloaded(Data([1])))
        XCTAssertThrowsError(try AskImageGenerationRetention(rootURL: root, scope: scope, callId: "x", metadata: Data(count: 65 * 1024)))
        XCTAssertThrowsError(try journal.published([]))
    }

    func testPublishedOutputReleasesRawBudgetButKeepsReplayFence() throws {
        let journal = try journal()
        try journal.response(Data("raw".utf8)); try journal.downloaded(Data("image".utf8))
        let store = AskArtifactStore(storageURL: root.appendingPathComponent("artifacts"))
        let ref = try store.publish(files: ["a.png": Data("original".utf8)], entry: "a.png", scope: scope)
        try journal.published([ref])
        let saved = try load(journal)
        XCTAssertNotNil(saved["published.json"])
        XCTAssertNil(saved["response.json"]); XCTAssertNil(saved["download-0"])
        XCTAssertThrowsError(try self.journal())
        XCTAssertEqual(try store.load(ref, scope: scope).files["a.png"], Data("original".utf8))
    }

    func testUnsafeLockedAndCorruptRetentionFailsClosed() throws {
        let journal = try journal()
        let directory = try AskSecureDirectory.openRoot(root)
        try directory.lock()
        XCTAssertThrowsError(try journal.response(Data("raw".utf8)))
        flock(directory.descriptor, LOCK_UN)
        let child = try directory.child(journal.id, privateDirectory: true)
        try child.createFile("unknown", data: Data())
        XCTAssertThrowsError(try load(journal))
        try child.remove("unknown")
        try child.remove("identity.json")
        try child.createFile("identity.json", data: Data("corrupt".utf8))
        XCTAssertThrowsError(try journal.response(Data()))
        XCTAssertThrowsError(try load(journal))
        try AskImageGenerationRetention.delete(rootURL: root, ownerId: scope.ownerId, conversationId: scope.conversationId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(journal.id).path))
    }

    func testDecoderFailureRetainsResponseUsageAndPartialOriginalWithoutSecondPOST() async throws {
        let first = try AskImageGenerationTests.picture()
        let second = Data("synthetic invalid image".utf8)
        let response = try JSONSerialization.data(withJSONObject: ["id": "paid-once", "usage": ["images": 2],
            "data": [["b64_json": first.base64EncodedString()], ["b64_json": second.base64EncodedString()]]])
        let transport = ImageTransportStub { _, _ in response }
        let journal = try journal()
        let root = self.root!, scope = self.scope
        let service = AskImageGenerationService(transport: transport, validate: { bytes in
            let saved = try AskImageGenerationRetention.load(rootURL: root, id: journal.id, scope: scope, callId: "call")
            XCTAssertEqual(saved["response.json"], response, "Retention must precede any decoder entry")
            if bytes == second { throw MediaFailure.unavailable }
            return .init(data: bytes, mediaType: "image/png", width: 8, height: 6)
        })
        let result = try await service.generate(.init(arguments: ["prompt": "test"]), configuration: .preset(.openAI), key: "key", retention: journal)
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(result.images.map(\.data), [first])
        XCTAssertEqual(result.unvalidatedImages, [second])
        XCTAssertEqual(result.requestID, "paid-once"); XCTAssertNotNil(result.usage)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try load(journal)["response.json"], response)
    }

    func testDownloadedOriginalSurvivesValidationFailureAndFollowingDownloadFailure() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["output": ["choices": [["message": ["content": [
            ["image": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png"],
            ["image": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/b.png"]]]]]]])
        let original = Data("downloaded bytes".utf8)
        let transport = ImageTransportStub { _, index in
            if index == 1 { return response }
            if index == 2 { return original }
            throw AskImageError.http(403)
        }
        let journal = try journal()
        let result = try await AskImageGenerationService(transport: transport, validate: { _ in throw MediaFailure.unavailable })
            .generate(.init(arguments: ["prompt": "test"]), configuration: .preset(.bailian), key: "key", retention: journal)
        XCTAssertTrue(result.incomplete); XCTAssertEqual(result.unvalidatedImages, [original])
        XCTAssertEqual(try load(journal)["download-0"], original)
        XCTAssertEqual(try load(journal)["response.json"], response)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(requests.count, 3)
    }

    func testDownloadRetentionWriteFailureStillReturnsBoundedOriginalForExport() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["output": ["choices": [["message": ["content": [
            ["image": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/a.png"]]]]]]])
        let original = Data("downloaded original".utf8)
        let journal = try journal(), root = self.root!
        let transport = ImageTransportStub { _, index in
            if index == 1 { return response }
            // A failed private write cannot make an already received image disappear.
            let directory = try AskSecureDirectory.openRoot(root).child(journal.id, privateDirectory: true)
            try directory.createFile("download-0", data: Data("disk collision".utf8))
            return original
        }
        let result = try await AskImageGenerationService(transport: transport, validate: { _ in XCTFail("Do not validate after failed retention"); throw MediaFailure.unavailable })
            .generate(.init(arguments: ["prompt": "test"]), configuration: .preset(.bailian), key: "key", retention: journal)
        XCTAssertTrue(result.incomplete); XCTAssertEqual(result.unvalidatedImages, [original])
        XCTAssertEqual(try load(journal)["response.json"], response)
    }

    func testGeneratedMetadataProtocolRejectsAmbiguousMissingAndUnsafeReplies() throws {
        let request = MediaRequest(operation: .validateGeneratedImage)
        var response = MediaResponse(id: request.id)
        XCTAssertThrowsError(try response.validate(for: request))
        response.generatedImage = .init(mediaType: "image/png", width: 8192, height: 2048)
        try response.validate(for: request)
        for metadata in [MediaGeneratedImage(mediaType: "image/gif", width: 1, height: 1),
                         .init(mediaType: "image/png", width: 0, height: 1),
                         .init(mediaType: "image/png", width: Int.max, height: 1),
                         .init(mediaType: "image/png", width: 8192, height: 2049)] {
            response.generatedImage = metadata; XCTAssertThrowsError(try response.validate(for: request))
        }
        response.generatedImage = .init(mediaType: "image/jpeg", width: 8, height: 6)
        response.items = [.init(text: "wrong", pages: 1)]
        XCTAssertThrowsError(try response.validate(for: request))
        response.items = []; response.failure = .unreadable
        XCTAssertThrowsError(try response.validate(for: request))
        response.failure = nil
        var unrelated = request; unrelated.operation = .image
        XCTAssertThrowsError(try response.validate(for: unrelated))
    }

    func testRealHelperValidatesOriginalPNGJPEGAndRejectsMalformedGIFAndDimensions() async throws {
        let validator = AskGeneratedImageValidator(worker: MediaWorker(timeout: 3))
        for type in [NSBitmapImageRep.FileType.png, .jpeg] {
            let data = try AskImageGenerationTests.picture(type)
            let result = try await validator.validate(data)
            XCTAssertEqual(result.data, data); XCTAssertEqual(result.width, 8); XCTAssertEqual(result.height, 6)
            XCTAssertEqual(result.mediaType, type == .png ? "image/png" : "image/jpeg")
        }
        let oversized = try AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 8193, height: 1), type: .png)
        let valid = try AskImageGenerationTests.picture()
        for data in [Data(), Data([0, 1, 2]), Data(valid.prefix(24)), oversized,
                     try AskImageGenerationTests.picture(.gif), Data(count: AskArtifactStore.maximumFileBytes + 1)] {
            do { _ = try await validator.validate(data); XCTFail("Invalid generated image accepted") } catch {}
        }
    }

    func testCancelledValidationRetainsOwnedWorkAndLimitsAdmission() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = MediaWorker(run: { process, _ in
            entered.signal(); release.wait()
            let request = try JSONDecoder().decode(MediaRequest.self, from: XCTUnwrap(process.stdin))
            var response = MediaResponse(id: request.id)
            response.generatedImage = .init(mediaType: "image/png", width: 1, height: 1)
            return .init(termination: .exited(0), exitCode: 0, stdout: String(decoding: try JSONEncoder().encode(response), as: UTF8.self), stderr: "", outputTruncated: false)
        })
        let validator = AskGeneratedImageValidator(worker: worker)
        let tasks = (0..<2).map { _ in Task { try await validator.validate(Data([1])) } }
        defer { for _ in tasks { release.signal() } }
        for _ in tasks {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var started = false
            while ContinuousClock.now < deadline {
                if entered.wait(timeout: .now()) == .success { started = true; break }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(started)
        }
        tasks.forEach { $0.cancel() }
        do { _ = try await validator.validate(Data([1])); XCTFail("Cancelled work still owns its admission") } catch {}
        for _ in tasks { release.signal() }
        for task in tasks { do { _ = try await task.value; XCTFail() } catch is CancellationError {} }
        XCTAssertEqual(worker.activeCount, 0)
    }
}
