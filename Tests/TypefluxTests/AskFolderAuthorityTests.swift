import Foundation
@testable import Typeflux
import XCTest

final class AskFolderAuthorityTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    func submission(_ store: AskFolderGrants, conversation: String = "c") -> AskFolderGrants.Scope {
        store.scope(ownerId: "o", deviceId: "d", conversationId: conversation, taskIdentity: UUID())
    }

    func admitted(_ store: AskFolderGrants, _ root: URL, lifetime: AskFolderGrants.Lifetime = .task,
                  conversation: String = "c") throws -> AskFolderGrants.Scope {
        var scope = submission(store, conversation: conversation)
        try store.stage([root.path], lifetime: lifetime, submissionScope: scope, messageID: "m")
        try store.bindSubmission(messageID: "m", admittedRun: "r", trustedScope: scope)
        scope.runId = "r"
        return scope
    }

    func testTaskIsolationAndPendingCannotExecute() throws {
        let root = try directory(), store = AskFolderGrants()
        let pending = submission(store)
        try store.stage([root.path, root.path], lifetime: .task, submissionScope: pending, messageID: "m")
        XCTAssertEqual(store.list(scope: pending).count, 1)
        XCTAssertTrue(store.roots(for: pending).isEmpty)
        var execution = pending; execution.runId = "r"
        XCTAssertThrowsError(try store.capture(root.path, executionScope: execution))
        try store.bindSubmission(messageID: "other", admittedRun: "r", trustedScope: pending)
        XCTAssertTrue(store.roots(for: execution).isEmpty)
        try store.bindSubmission(messageID: "m", admittedRun: "r", trustedScope: pending)
        XCTAssertEqual(store.roots(for: execution), [root.path])
        let lease = try store.capture(root.path, executionScope: execution)
        try store.validate(lease)
        let variants = [
            AskFolderGrants.Scope(
                ownerId: "other",
                deviceId: "d",
                sessionEpoch: pending.sessionEpoch,
                conversationId: "c",
                taskIdentity: pending.taskIdentity,
                runId: "r"
            ),
            AskFolderGrants.Scope(
                ownerId: "o",
                deviceId: "other",
                sessionEpoch: pending.sessionEpoch,
                conversationId: "c",
                taskIdentity: pending.taskIdentity,
                runId: "r"
            ),
            AskFolderGrants.Scope(
                ownerId: "o",
                deviceId: "d",
                sessionEpoch: UUID(),
                conversationId: "c",
                taskIdentity: pending.taskIdentity,
                runId: "r"
            ),
            AskFolderGrants.Scope(
                ownerId: "o",
                deviceId: "d",
                sessionEpoch: pending.sessionEpoch,
                conversationId: "other",
                taskIdentity: pending.taskIdentity,
                runId: "r"
            )
        ]
        for scope in variants {
            XCTAssertTrue(store.roots(for: scope).isEmpty)
        }
        var changed = execution; changed.runId = "other"
        XCTAssertTrue(store.roots(for: changed).isEmpty)
        XCTAssertThrowsError(try store.bindSubmission(messageID: "m", admittedRun: "other", trustedScope: pending))
        changed = execution; changed.taskIdentity = UUID()
        XCTAssertTrue(store.roots(for: changed).isEmpty)
        store.revoke(lease.grant.id, scope: variants[0]); try store.validate(lease)
        store.revoke(lease.grant.id, scope: pending)
        XCTAssertThrowsError(try store.validate(lease))
        _ = try admitted(store, root)
        XCTAssertThrowsError(try store.validate(lease), "Same path reauthorization cannot revive a lease")
    }

    func testSessionLifetimeChangeAndReset() throws {
        let root = try directory(), store = AskFolderGrants()
        let task = try admitted(store, root)
        let taskLease = try store.capture(root.path, executionScope: task)
        var sessionRun = try admitted(store, root, lifetime: .conversationSession)
        XCTAssertThrowsError(try store.validate(taskLease))
        let sessionLease = try store.capture(root.path, executionScope: sessionRun)
        sessionRun.runId = "new-run"; sessionRun.taskIdentity = UUID()
        XCTAssertEqual(store.roots(for: sessionRun), [root.path])
        store.revokeTask(scope: task)
        try store.validate(sessionLease)
        store.revokeConversation(scope: task)
        XCTAssertThrowsError(try store.validate(sessionLease))
        let fresh = try admitted(store, root, lifetime: .conversationSession)
        let freshLease = try store.capture(root.path, executionScope: fresh)
        store.resetSession()
        XCTAssertThrowsError(try store.validate(freshLease))
        XCTAssertTrue(store.list(scope: fresh).isEmpty)
        XCTAssertNotEqual(store.scope(ownerId: "o", deviceId: "d", conversationId: "c").sessionEpoch, task.sessionEpoch)
        XCTAssertThrowsError(try store.stage([root.path], lifetime: .task, submissionScope: task, messageID: "m"))
    }

    func testReplacementLegacyAndSubmissionDiscard() throws {
        let root = try directory(), store = AskFolderGrants()
        let scope = try admitted(store, root)
        let lease = try store.capture(root.path, executionScope: scope)
        let moved = root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.validate(lease))
        let staged = submission(store)
        try store.stage([root.path], lifetime: .task, submissionScope: staged, messageID: "new")
        store.revokeSubmission(messageID: "new", scope: staged)
        XCTAssertTrue(store.list(scope: staged).isEmpty)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        try defaults.set(JSONSerialization.data(withJSONObject: [["conversationId": "c", "paths": [root.path]]]),
                         forKey: AskFolderGrants.defaultsKey)
        let restarted = AskFolderGrants(defaults: defaults)
        XCTAssertTrue(restarted.roots(for: scope).isEmpty)
        XCTAssertTrue(restarted.list(scope: restarted.scope(ownerId: "o", deviceId: "d", conversationId: "c")).isEmpty)
    }

    func testHardBoundsRejectAtomicallyInsteadOfEvicting() throws {
        let root = try directory(), store = AskFolderGrants()
        for index in 0 ..< AskFolderGrants.maximumConversations {
            _ = try admitted(store, root, conversation: "c\(index)")
        }
        XCTAssertThrowsError(try admitted(store, root, conversation: "overflow"))
        XCTAssertEqual(store.list(scope: submission(store, conversation: "c0")).count, 1)
        store.resetSession()
        let scope = submission(store)
        var roots: [String] = []
        for index in 0 ... AskFolderGrants.maximumRoots {
            let child = root.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            roots.append(child.path)
        }
        try store.stage(Array(roots.prefix(32)), lifetime: .task, submissionScope: scope, messageID: "m")
        XCTAssertThrowsError(try store.stage(roots, lifetime: .task, submissionScope: scope, messageID: "m"))
        XCTAssertEqual(store.list(scope: scope).count, 32)
        for path in ["relative", "/" + String(repeating: "a", count: 4096), "/a\0b"] {
            XCTAssertThrowsError(try store.stage([path], lifetime: .task, submissionScope: scope, messageID: "m"))
        }
    }
}
