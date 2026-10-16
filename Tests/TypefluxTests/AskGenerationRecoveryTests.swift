import AppKit
import SwiftUI
import XCTest
@testable import Typeflux

@MainActor final class AskGenerationRecoveryTests: XCTestCase {
    var root: URL!
    let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("generation-recovery-" + UUID().uuidString).appendingPathComponent("retention")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    func journal(_ call: String = "call") throws -> AskImageGenerationRetention {
        try .init(rootURL: root, scope: scope, callId: call, metadata: Data("request".utf8))
    }
    func records() throws -> [AskGenerationRecoveryRecord] {
        try AskImageGenerationRetention.recoveryRecords(rootURL: root, owner: scope.ownerId, conversation: scope.conversationId)
    }
    func read(_ record: AskGenerationRecoveryRecord, _ name: String) throws -> Data {
        try AskImageGenerationRetention.recoveryFile(rootURL: root, record: record, owner: scope.ownerId,
                                                     conversation: scope.conversationId, name: name)
    }

    func testReopenListsPartialResponseWithoutDecodingAndKeepsReplayFence() throws {
        let journal = try journal()
        try journal.response(Data("{broken provider response".utf8))
        try journal.downloaded(Data([0, 255, 1]))
        let record = try XCTUnwrap(records().first)
        XCTAssertEqual(record.id, journal.id)
        XCTAssertEqual(record.files, ["download-0", "request.json", "response.json"])
        XCTAssertEqual(try read(record, "response.json"), Data("{broken provider response".utf8))
        XCTAssertEqual(try read(record, "download-0"), Data([0, 255, 1]))
        XCTAssertEqual(try read(record, "request.json"), Data("request".utf8))
        XCTAssertThrowsError(try self.journal())
        XCTAssertThrowsError(try read(record, "identity.json"))
        XCTAssertThrowsError(try read(record, "../response.json"))
        var forged = record; forged.callId = "another"
        XCTAssertThrowsError(try read(forged, "response.json"))
        forged = record; forged.id = "../bad"
        XCTAssertThrowsError(try read(forged, "response.json"))
        XCTAssertEqual(try AskImageGenerationRetention.recoveryRecords(rootURL: root, owner: "other", conversation: scope.conversationId), [])
        XCTAssertThrowsError(try AskImageGenerationRetention.recoveryRecords(rootURL: root, owner: "", conversation: scope.conversationId))
    }

    func testEmptyPublishedAndQuotaRemainConservative() throws {
        XCTAssertEqual(try records(), [])
        let journal = try journal()
        let store = AskArtifactStore(storageURL: root.deletingLastPathComponent().appendingPathComponent("artifacts"))
        let ref = try store.publish(files: ["result.bin": Data([1])], entry: "result.bin", scope: scope)
        try journal.published([ref])
        XCTAssertEqual(try records(), [])
        for i in 0..<8 { _ = try self.journal("pending-\(i)") }
        XCTAssertEqual(try records().count, 8)
        XCTAssertThrowsError(try self.journal("over-budget"))
        // Viewing/exporting cannot make a pending call disappear from admission.
        let record = try XCTUnwrap(records().first)
        _ = try read(record, "request.json")
        XCTAssertThrowsError(try self.journal("still-over-budget"))
    }

    func testCorruptIdentityAndSymlinkNeverExposeBytes() throws {
        let journal = try journal()
        let record = try XCTUnwrap(records().first)
        let path = root.appendingPathComponent(journal.id)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("download-0"), withDestinationURL: root.appendingPathComponent("secret"))
        XCTAssertThrowsError(try read(record, "download-0"))
        let oversized = path.appendingPathComponent("response.json")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(AskImageGenerationService.maximumResponseBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try read(record, "response.json"))
        try Data("invalid".utf8).write(to: path.appendingPathComponent("identity.json"))
        XCTAssertEqual(try records(), [])
        XCTAssertThrowsError(try read(record, "request.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testSuccessfulSaveRetainsOriginalAndDoesNotPublishOrResetIdentity() async throws {
        let journal = try journal(); try journal.response(Data("raw".utf8))
        let model = AskGenerationRecoveryModel()
        await model.load(root: root, owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        let record = try XCTUnwrap(model.records.first)
        let output = root.deletingLastPathComponent().appendingPathComponent("export.json")
        await model.save(record, name: "response.json", destination: output, root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        XCTAssertEqual(try Data(contentsOf: output), Data("raw".utf8))
        XCTAssertEqual(try read(record, "response.json"), Data("raw".utf8))
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.message)
        XCTAssertThrowsError(try self.journal())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(journal.id).appendingPathComponent("published.json").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(".typeflux-recovery-") }))
    }

    func testRevocationAfterReadClearsDisplayAndPreventsCommit() async throws {
        _ = try journal()
        let model = AskGenerationRecoveryModel()
        var checks = 0
        await model.load(root: root, owner: scope.ownerId, conversation: scope.conversationId, authorize: {
            checks += 1; if checks == 2 { throw AskArtifactError.denied }
        })
        XCTAssertTrue(model.records.isEmpty); XCTAssertNotNil(model.message)
        let record = try XCTUnwrap(records().first)
        let output = root.deletingLastPathComponent().appendingPathComponent("export.json")
        try Data("existing".utf8).write(to: output)
        checks = 0
        await model.save(record, name: "request.json", destination: output, root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: {
            checks += 1; if checks == 2 { throw AskArtifactError.denied }
        })
        XCTAssertEqual(try Data(contentsOf: output), Data("existing".utf8))
        XCTAssertEqual(try read(record, "request.json"), Data("request".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.deletingLastPathComponent().path).contains(where: { $0.hasPrefix(".typeflux-recovery-") }))
    }

    func testCloseAndCancellationRejectLateDisplayAndNewSaves() async throws {
        _ = try journal()
        let model = AskGenerationRecoveryModel()
        let task = Task { await model.load(root: root, owner: scope.ownerId, conversation: scope.conversationId, authorize: {}) }
        task.cancel(); await task.value
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.message)
        let loading = Task { await model.load(root: root, owner: scope.ownerId, conversation: scope.conversationId, authorize: {}) }
        await Task.yield(); model.cancel(); await loading.value
        XCTAssertTrue(model.records.isEmpty); XCTAssertFalse(model.busy)
        let record = try XCTUnwrap(records().first)
        await model.save(record, name: "request.json", destination: root.appendingPathComponent("never"), root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: { XCTFail("Closed view must not submit") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never").path))
    }

    func testReadAndExportFailuresAreRedactedAndRetainOriginal() async throws {
        _ = try journal()
        let record = try XCTUnwrap(records().first)
        let model = AskGenerationRecoveryModel()
        await model.save(record, name: "request.json", destination: root.deletingLastPathComponent().appendingPathComponent("missing/out"), root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        XCTAssertNotNil(model.message); XCTAssertFalse(model.message?.contains(root.path) ?? true)
        XCTAssertEqual(try read(record, "request.json"), Data("request".utf8))
        await model.load(root: root, owner: scope.ownerId, conversation: scope.conversationId,
                         authorize: { throw AskArtifactError.denied })
        XCTAssertTrue(model.records.isEmpty)
    }

    func testExportCannotOverwriteJournalAndFailedCommitPreservesSource() async throws {
        let journal = try journal()
        let record = try XCTUnwrap(records().first)
        let model = AskGenerationRecoveryModel()
        let identity = root.appendingPathComponent(journal.id).appendingPathComponent("identity.json")
        let before = try Data(contentsOf: identity)
        await model.save(record, name: "request.json", destination: identity, root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        XCTAssertEqual(try Data(contentsOf: identity), before)
        XCTAssertNotNil(model.message)
        let destination = root.deletingLastPathComponent().appendingPathComponent("existing-directory")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await model.save(record, name: "request.json", destination: destination, root: root,
                         owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        XCTAssertNotNil(model.message)
        XCTAssertEqual(try read(record, "request.json"), Data("request".utf8))
    }

    func testAdmissionRetainsCancelledDiskWorkAndRejectsThirdRequest() async throws {
        let gate = RecoveryDiskGate()
        let first = Task { try await AskGenerationRecoveryIO.perform { gate.block() } }
        let second = Task { try await AskGenerationRecoveryIO.perform { gate.block() } }
        for _ in 0..<200 where gate.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gate.count, 2)
        first.cancel()
        do { _ = try await AskGenerationRecoveryIO.perform { 3 }; XCTFail("No replacement before retirement") } catch {}
        gate.release.signal(); gate.release.signal()
        do { _ = try await first.value; XCTFail("Cancellation must win") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        _ = try await second.value
        let admitted = try await AskGenerationRecoveryIO.perform { 4 }
        XCTAssertEqual(admitted, 4)
    }

    func testRecoverySheetShowsPrivateLocalFilesAndClearsOnClose() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        defer { NSApp.accessibilitySetValue(false, forAttribute: .init(rawValue: "AXEnhancedUserInterface")) }
        let journal = try journal("image-call-001")
        try journal.response(Data("incomplete".utf8)); try journal.downloaded(Data([1, 2]))
        let model = AskGenerationRecoveryModel()
        let access = AskGenerationRecoveryAccess(root: root, owner: scope.ownerId, conversation: scope.conversationId, authorize: {})
        let output = root.deletingLastPathComponent().appendingPathComponent("saved-response.json")
        let view = NSHostingView(rootView: AskGenerationRecoveryView(access: access, close: {}, model: model, destination: { _ in output })
            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 360)
        for _ in 0..<200 where model.records.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.records.count, 1)
        view.layoutSubtreeIfNeeded()
        var seen = Set<ObjectIdentifier>()
        func descendants(_ element: Any) -> [NSObject] {
            guard let object = element as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = object.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? object.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            return [object] + children.flatMap(descendants)
        }
        var matching: NSObject?
        for _ in 0..<200 {
            seen = []
            matching = descendants(window).first {
                $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) &&
                    $0.value(forKey: "accessibilityIdentifier") as? String == "generation.recovery.save.response.json"
            }
            if matching != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let button = try XCTUnwrap(matching)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let press = unsafeBitCast(button.method(for: selector), to: Press.self)
        XCTAssertTrue(press(button, selector))
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: output.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try Data(contentsOf: output), Data("incomplete".utf8))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/generation-recovery-validation")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("recovery.png"))
        window.contentView = nil
        for _ in 0..<100 where !model.records.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertEqual(try read(try XCTUnwrap(records().first), "download-0"), Data([1, 2]))
    }

    func testProductionAccessFencesSelectionAccountTokenAndLogout() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: defaults)),
                                  artifactStore: AskArtifactStore(storageURL: root.deletingLastPathComponent().appendingPathComponent("artifacts")))
        let cache = try AskConversationCache(url: root.deletingLastPathComponent().appendingPathComponent("cache.sqlite"))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        var account: (owner: String, token: String)? = ("owner", "token")
        let api = AskTestAPI()
        await api.seed(AskConversation(id: "conversation", title: "Recovery", revision: 1, updatedAt: Date(), messages: []))
        let model = AskConversationModel(api: api, cache: cache, tools: tools, capture: AskTestCapture(),
            deviceId: "test", modelLibrary: library, defaults: defaults, session: { account })
        defer { model.resetSession() }
        XCTAssertNil(model.generationRecoveryAccess)
        await model.select("conversation")
        let access = try XCTUnwrap(model.generationRecoveryAccess)
        XCTAssertNoThrow(try access.authorize())
        model.selectionGeneration = UUID()
        XCTAssertThrowsError(try access.authorize())
        let fresh = try XCTUnwrap(model.generationRecoveryAccess)
        let workspace = NSHostingView(rootView: AskConversationView(model: model))
        workspace.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        workspace.layoutSubtreeIfNeeded()
        account = ("other", "token")
        XCTAssertThrowsError(try fresh.authorize())
        account = ("owner", "changed")
        XCTAssertThrowsError(try fresh.authorize())
        account = nil
        XCTAssertThrowsError(try fresh.authorize())
        XCTAssertNil(model.generationRecoveryAccess)
        account = ("owner", "token")
        XCTAssertNoThrow(try fresh.authorize())
        await model.delete("conversation")
        XCTAssertThrowsError(try fresh.authorize())
        XCTAssertNil(model.generationRecoveryAccess)
    }
}

private final class RecoveryDiskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.withLock { entered } }
    func block() -> Int { lock.withLock { entered += 1 }; release.wait(); return 1 }
}
