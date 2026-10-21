import Foundation
@testable import Typeflux
import XCTest

/// A deterministic suspension in the worker, with no timing sleeps.
private final class FileSuspension: @unchecked Sendable {
    let entered: XCTestExpectation
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false
    let event: String
    init(_ event: String, entered: XCTestExpectation) {
        self.event = event; self.entered = entered
    }

    func visit(_ event: String) throws {
        lock.lock()
        let shouldWait = self.event == event && !used
        if shouldWait {
            used = true
        }
        lock.unlock()
        if shouldWait {
            entered.fulfill()
            guard resume.wait(timeout: .now() + 30) == .success
            else { throw AskFileAccess.error("Test suspension was not resumed") }
        }
    }

    func release() {
        resume.signal()
    }
}

@MainActor
final class AskFileDispatchTests: XCTestCase {
    func call(_ action: String, path: String = "file", extra: [String: Any] = [:]) throws -> AskToolCall {
        let args = extra.merging(["action": action, "path": path]) { original, _ in original }
        return try .init(
            id: UUID().uuidString,
            function: .init(
                name: "files",
                arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            )
        )
    }

    func fixture() throws -> (URL, AskLocalTools, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-dispatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.askFileAccessFolders = [root.path]
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: .init(defaults: defaults)), settings: settings)
        return (root, tools, defaults)
    }

    func testActualRawAndApprovedDispatchForwardCancellationAndJoinWorker() async throws {
        for (action, event, approved) in [("read", "read", false), ("search", "entry", false), ("read", "read", true),
                                          ("write", "staged", true), ("write", "precommit", true)] {
            let (root, tools, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let version = try AskFileTools(roots: [root.path]).readPage("file").version
            let request = try call(
                action,
                path: action == "search" ? "." : "file",
                extra: ["content": "new", "expected_version": version, "pattern": "original"]
            )
            let binding = approved ? try await tools.approvalBinding(for: request, conversationId: "c") : nil
            let entered = expectation(description: "worker suspended at \(event)")
            let suspension = FileSuspension(event, entered: entered)
            tools.fileOperationHooks.onEvent = { try suspension.visit($0) }
            let owner = Task {
                if let binding {
                    return try await tools.executeApproved(
                        request,
                        conversationId: "c",
                        binding: binding,
                        authorize: {}
                    )
                }
                return try await tools.execute(request, conversationId: "c")
            }
            await fulfillment(of: [entered], timeout: 30)
            owner.cancel(); suspension.release()
            do { _ = try await owner.value; XCTFail("Cancellation must reach the file worker") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix(".typeflux-write-") })
        }
    }

    func testRevokedGrantBeforeReleaseAndCommit() async throws {
        for action in ["read", "write"] {
            let (root, tools, defaults) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let version = try AskFileTools(roots: [root.path]).readPage("file").version
            let request = try call(action, extra: ["content": "new", "expected_version": version])
            let binding = try await tools.approvalBinding(for: request, conversationId: "c")
            let entered = expectation(description: "before release/commit")
            let suspension = FileSuspension(action == "read" ? "release" : "precommit", entered: entered)
            tools.fileOperationHooks.onEvent = { try suspension.visit($0) }
            let owner = Task { try await tools.executeApproved(
                request,
                conversationId: "c",
                binding: binding,
                authorize: {}
            ) }
            await fulfillment(of: [entered], timeout: 30)
            defaults.set([], forKey: "ask.fileAccessFolders"); suspension.release()
            do { _ = try await owner.value; XCTFail("Revoked root must be refused") } catch {}
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
        }
    }

    func testCancellationAfterCommitRetainsSuccessfulReceipt() async throws {
        let (root, tools, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try call("write", path: "created", extra: ["content": "created"])
        let binding = try await tools.approvalBinding(for: request, conversationId: "c")
        let committed = expectation(description: "committed")
        let resume = DispatchSemaphore(value: 0)
        tools.fileOperationHooks.onCommit = { committed.fulfill(); _ = resume.wait(timeout: .now() + 30) }
        let owner = Task {
            try await tools.executeApproved(request, conversationId: "c", binding: binding, authorize: {})
        }
        await fulfillment(of: [committed], timeout: 30)
        owner.cancel(); resume.signal()
        let receipt = try await owner.value
        XCTAssertTrue(receipt.content.hasPrefix("Created"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("created")), "created")
    }

    func testConcurrentTypefluxWritersHaveOneConflict() async throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = AskFileTools(roots: [root.path])
        let version = try tools.readPage("file").version
        let entered = expectation(description: "first writer preparing")
        let suspension = FileSuspension("prepared", entered: entered)
        var first = tools
        first.hooks.onEvent = { try suspension.visit($0) }
        let firstWorker = Task
            .detached { [first] in try first.write("file", content: "first", expectedVersion: version) }
        await fulfillment(of: [entered], timeout: 30)
        let secondStarted = expectation(description: "second writer started")
        let secondWorker = Task.detached {
            secondStarted.fulfill()
            return try tools.write("file", content: "second", expectedVersion: version)
        }
        await fulfillment(of: [secondStarted], timeout: 30)
        suspension.release()
        let receipt = try await firstWorker.value
        XCTAssertTrue(receipt.hasPrefix("Replaced"))
        do { _ = try await secondWorker.value; XCTFail("Second stale writer must conflict") } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "first")
    }

    func testCoordinatedEditorFinishesBeforeTypefluxChecksExpectedVersion() async throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AskFileTools(roots: [root.path])
        let version = try files.readPage("file").version
        let entered = expectation(description: "editor owns coordinated writer section")
        let suspension = FileSuspension("editor", entered: entered)
        let editor = Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var failure: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(
                writingItemAt: root.appendingPathComponent("file"),
                options: .forReplacing,
                error: &failure
            ) { url in
                result = Result {
                    try suspension.visit("editor")
                    try Data("editor update".utf8).write(to: url)
                }
            }
            if let failure {
                throw failure
            }
            guard let result else { throw AskFileAccess.denied }
            try result.get()
        }
        await fulfillment(of: [entered], timeout: 30)
        let started = expectation(description: "Typeflux writer started")
        let writer = Task.detached {
            started.fulfill()
            return try files.write("file", content: "stale overwrite", expectedVersion: version)
        }
        await fulfillment(of: [started], timeout: 30)
        suspension.release()
        try await editor.value
        do { _ = try await writer.value; XCTFail("Coordinated editor update must conflict") } catch {}
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "editor update")
    }
}
