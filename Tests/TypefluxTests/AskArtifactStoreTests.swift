import Darwin
@testable import Typeflux
import XCTest

final class AskArtifactStoreTests: XCTestCase {
    var base: URL!
    var store: AskArtifactStore!
    let scope = AskProjectScope(ownerId: "owner", conversationId: "conversation", runId: "run")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        store = AskArtifactStore(
            storageURL: base.appendingPathComponent("artifacts"),
            now: { Date(timeIntervalSince1970: 100) }
        )
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
    }

    func publish(_ data: Data = Data("hello".utf8), entry: String = "note.txt") throws -> AskArtifactRef {
        try store.publish(files: [entry: data], entry: entry, scope: scope)
    }

    func testPersistReopenExportAndIntegrity() throws {
        let files = ["site/index.html": Data("<h1>Hello</h1>".utf8), "site/app.js": Data("console.log(1)".utf8)]
        let ref = try store.publish(files: files, entry: "site/index.html", scope: scope)
        XCTAssertEqual(ref.mediaType, "text/html")
        XCTAssertEqual(ref.sizeBytes, 14)
        XCTAssertEqual(ref.expiresAt, Date(timeIntervalSince1970: 100 + AskArtifactStore.retention))
        store = AskArtifactStore(storageURL: store.storageURL, now: { Date(timeIntervalSince1970: 101) })
        let bundle = try store.load(ref, scope: scope)
        XCTAssertEqual(bundle.files, files)
        XCTAssertEqual(bundle.manifest.createdAt, Date(timeIntervalSince1970: 100))
        let output = base.appendingPathComponent("export.html")
        try AskArtifactExport.write(bundle, to: output)
        XCTAssertEqual(try AskToolPolicy.digest(Data(contentsOf: output)), ref.sha256)
        var corrupted = bundle
        corrupted.files[bundle.manifest.entry] = Data("bad".utf8)
        XCTAssertThrowsError(try AskArtifactExport.write(corrupted, to: output))
        XCTAssertThrowsError(try AskArtifactExport.write(bundle, to: base.appendingPathComponent("missing/file")))
        let metadata = try String(contentsOf: store.storageURL.appendingPathComponent(ref.id + "/manifest.json"))
        XCTAssertFalse(metadata.contains(base.path))
    }

    func testAccessRejectsOwnersRunsConversationsAndForgedRefs() throws {
        let ref = try publish()
        for wrong in [AskProjectScope(ownerId: "other", conversationId: scope.conversationId, runId: scope.runId),
                      .init(ownerId: scope.ownerId, conversationId: "other", runId: scope.runId),
                      .init(ownerId: scope.ownerId, conversationId: scope.conversationId, runId: "other")] {
            XCTAssertThrowsError(try store.load(ref, scope: wrong))
        }
        var bad = ref
        bad.id = "../outside"
        XCTAssertThrowsError(try store.load(bad, scope: scope))
        bad = ref; bad.sha256 = "forged"
        XCTAssertThrowsError(try store.load(bad, scope: scope))
        bad = ref; bad.cleanup = "user_managed"
        XCTAssertThrowsError(try store.load(bad, scope: scope))
        bad = ref; bad.expiresAt = nil
        XCTAssertThrowsError(try store.load(bad, scope: scope))
        bad = ref; bad.id = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try store.load(bad, scope: scope)) { XCTAssertEqual($0 as? AskArtifactError, .unavailable)
        }
        let otherDevice = AskArtifactStore(storageURL: base.appendingPathComponent("other-device"), now: store.now)
        XCTAssertThrowsError(try otherDevice.load(ref, scope: scope)) { XCTAssertEqual(
            $0 as? AskArtifactError,
            .unavailable
        ) }
    }

    func testPathAliasesLimitsAndMimePolicy() throws {
        for path in ["../x", "/x", "a/../x", "a//x", ".git/config", "x\\y", "%2e%2e/x", "a?b", "a#b", "a\n"] {
            XCTAssertThrowsError(try publish(entry: path), path)
        }
        XCTAssertThrowsError(try store.publish(files: ["A.txt": Data(), "a.txt": Data()], entry: "A.txt", scope: scope))
        XCTAssertThrowsError(try store.publish(files: [:], entry: "missing", scope: scope))
        XCTAssertThrowsError(try store.publish(files: ["x": Data()], entry: "missing", scope: scope))
        XCTAssertThrowsError(try store.publish(
            files: ["x": Data()],
            entry: "x",
            scope: .init(ownerId: "", conversationId: "c", runId: "r")
        ))
        XCTAssertThrowsError(try store.publish(
            files: Dictionary(uniqueKeysWithValues: (0 ... 128).map { (String($0), Data()) }),
            entry: "0",
            scope: scope
        ))
        XCTAssertThrowsError(try publish(Data(repeating: 0, count: AskArtifactStore.maximumFileBytes + 1)))
        let large = Data(repeating: 0, count: AskArtifactStore.maximumFileBytes)
        XCTAssertThrowsError(try store.publish(
            files: ["a": large, "b": large, "c": Data([1])],
            entry: "a",
            scope: scope
        ))
        for (path, mime) in ["x.htm": "text/html", "x.log": "text/plain", "x.md": "text/plain", "x.css": "text/css",
                             "x.js": "application/javascript", "x.json": "application/json", "x.PNG": "image/png",
                             "x.jpg": "image/jpeg", "x.gif": "image/gif", "x.svg": "application/octet-stream"] {
            let ref = try publish(entry: path)
            XCTAssertEqual(ref.mediaType, mime)
            XCTAssertEqual(try store.load(ref, scope: scope).files[path], Data("hello".utf8))
        }
    }

    func testRetentionOnlyRemovesExpiredPrivateRecords() throws {
        let expired = try publish()
        store.now = { Date(timeIntervalSince1970: 101) }
        let keep = try publish(entry: "keep.txt")
        let root = try AskSecureDirectory.openRoot(store.storageURL)
        try root.createFile("unrelated", data: Data("keep".utf8))
        let corrupt = try root.child(UUID().uuidString.lowercased(), create: true, privateDirectory: true)
        try corrupt.createFile("manifest.json", data: Data("bad".utf8))
        store.now = { Date(timeIntervalSince1970: 100 + AskArtifactStore.retention) }
        XCTAssertThrowsError(try store.load(expired, scope: scope)) { XCTAssertEqual($0 as? AskArtifactError, .expired)
        }
        XCTAssertEqual(try store.cleanupExpired(), 1)
        XCTAssertEqual(try store.cleanupExpired(), 0)
        XCTAssertNoThrow(try store.load(keep, scope: scope))
        XCTAssertEqual(try root.readFile("unrelated", limit: 10), Data("keep".utf8))
    }

    func testImagesSurviveCleanupAndReopenUntilConversationDeletion() throws {
        for entry in ["image.png", "image.jpg", "image.gif"] {
            let ref = try publish(entry: entry)
            XCTAssertEqual(ref.cleanup, "device_persistent")
            XCTAssertNil(ref.expiresAt)
            XCTAssertNil(AskArtifactStore.expirationDate(for: ref))
            let reopened = try AskCoding.decoder().decode(AskArtifactRef.self, from: AskCoding.encoder().encode(ref))
            let future = AskArtifactStore(
                storageURL: store.storageURL,
                now: { Date(timeIntervalSince1970: 2_000_000_000) }
            )
            XCTAssertEqual(try future.cleanupExpired(), 0)
            let bundle = try future.load(reopened, scope: scope)
            XCTAssertEqual(bundle.files[entry], Data("hello".utf8))
            try future.validate(reopened, scope: scope) { _ in XCTFail("Unexpected workspace") }
            let exported = base.appendingPathComponent(entry)
            try AskArtifactExport.write(bundle, to: exported)
            XCTAssertEqual(try Data(contentsOf: exported), Data("hello".utf8))
            try future.delete(ownerId: "other", conversationId: scope.conversationId)
            XCTAssertNoThrow(try future.load(ref, scope: scope))
            try future.delete(ownerId: scope.ownerId, conversationId: scope.conversationId)
            XCTAssertThrowsError(try future.load(ref, scope: scope))
        }
    }

    func testLegacyImagesRemainReadableAfterTheirOriginalExpiry() throws {
        var ref = try publish(entry: "generated-1.png")
        var manifest = try store.load(ref, scope: scope).manifest
        ref.cleanup = "device_30_days"
        ref.expiresAt = Date(timeIntervalSince1970: 100 + AskArtifactStore.retention)
        manifest.ref = ref
        let manifestURL = store.storageURL.appendingPathComponent(ref.id + "/manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let originalManifest = try Data(contentsOf: manifestURL)
        let oldRef = try AskCoding.decoder().decode(AskArtifactRef.self, from: AskCoding.encoder().encode(ref))
        let expiredText = try publish()
        store.now = { Date(timeIntervalSince1970: 2_000_000_000) }
        XCTAssertNil(AskArtifactStore.expirationDate(for: oldRef))
        XCTAssertNoThrow(try store.load(oldRef, scope: scope))
        XCTAssertEqual(try store.cleanupExpired(), 1)
        XCTAssertEqual(try store.cleanupExpired(), 0)
        XCTAssertEqual(try store.load(oldRef, scope: scope).manifest.ref, oldRef)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        XCTAssertThrowsError(try store.load(expiredText, scope: scope))
    }

    func testPersistentPolicyCannotBypassReferenceIntegrity() throws {
        let text = try publish()
        var forged = text
        forged.cleanup = "device_persistent"
        forged.expiresAt = nil
        XCTAssertThrowsError(try store.load(forged, scope: scope))
        forged.mediaType = "image/png"
        XCTAssertThrowsError(try store.load(forged, scope: scope))
        let image = try publish(entry: "image.png")
        forged = image
        forged.expiresAt = Date()
        XCTAssertThrowsError(try store.load(forged, scope: scope))
        forged = image
        forged.sha256 = "forged"
        XCTAssertThrowsError(try store.load(forged, scope: scope))
    }

    func testTamperingSymlinksAndHardlinksAreRejected() throws {
        let ref = try publish()
        let file = store.storageURL.appendingPathComponent(ref.id + "/0")
        try Data("evil!".utf8).write(to: file)
        XCTAssertThrowsError(try store.load(ref, scope: scope))
        try FileManager.default.removeItem(at: file)
        let outside = base.appendingPathComponent("outside")
        try Data("hello".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.load(ref, scope: scope))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(link(outside.path, file.path), 0)
        XCTAssertThrowsError(try store.load(ref, scope: scope))
        XCTAssertEqual(try Data(contentsOf: outside), Data("hello".utf8))
        let linked = AskArtifactStore(storageURL: base.appendingPathComponent("linked"))
        try FileManager.default.createSymbolicLink(at: linked.storageURL, withDestinationURL: store.storageURL)
        XCTAssertThrowsError(try linked.publish(files: ["x": Data()], entry: "x", scope: scope))
    }

    func testWorkspaceMetadataRequiresLiveAuthorization() throws {
        let workspace = AskWorkspaceRef(id: "workspace", ownerId: scope.ownerId, conversationId: scope.conversationId,
                                        runId: scope.runId, version: "1", cleanup: "user_managed")
        let ref = try store.publish(files: ["log.txt": Data()], entry: "log.txt", scope: scope, workspace: workspace)
        XCTAssertThrowsError(try store.load(ref, scope: scope))
        XCTAssertNoThrow(try store.load(ref, scope: scope) { XCTAssertEqual($0, workspace) })
        var wrong = workspace; wrong.runId = "wrong"
        XCTAssertThrowsError(try store.publish(files: ["x": Data()], entry: "x", scope: scope, workspace: wrong))
    }

    func testWireDatePrecisionDoesNotInvalidateReopenedReferences() throws {
        store.now = { Date(timeIntervalSince1970: 100.987654321) }
        let ref = try publish()
        let reopened = try AskCoding.decoder().decode(AskArtifactRef.self, from: AskCoding.encoder().encode(ref))
        XCTAssertEqual(reopened, ref)
        XCTAssertNoThrow(try store.load(reopened, scope: scope))
    }
}
