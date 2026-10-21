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

/// Values inspected by the test actor and the synchronous descriptor worker.
private final class FileEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var revoked = false

    func record(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func count(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0 == event }.count
    }

    func revoke() {
        lock.lock(); defer { lock.unlock() }
        revoked = true
    }

    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        if revoked {
            throw AskFileAccess.denied
        }
    }
}

/// An editor that keeps ownership until the test explicitly relinquishes it.
/// Its request callback proves the coordinator is already waiting in Foundation.
private final class HeldFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let requested: XCTestExpectation
    private let lock = NSLock()
    private var pending: (@Sendable ((@Sendable () -> Void)?) -> Void)?
    private var released = false

    init(url: URL, requested: XCTestExpectation) {
        presentedItemURL = url
        self.requested = requested
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        lock.lock()
        let alreadyReleased = released
        if !alreadyReleased {
            pending = writer
        }
        lock.unlock()
        requested.fulfill()
        if alreadyReleased {
            writer(nil)
        }
    }

    func release() {
        lock.lock()
        released = true
        let writer = pending
        pending = nil
        lock.unlock()
        writer?(nil)
    }
}

extension AskFileDispatchTests {
    /// Direct calls and both real host entry points must finish B before A is
    /// released. Timeouts measure failures; they never establish test ordering.
    func testCancelledGateWaitDoesNotDependOnSameOrUnrelatedWriter() async throws {
        for dispatch in 1 ... 2 {
            for path in ["file", "new/nested/file"] {
                let (root, host, _) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                var first = AskFileTools(roots: [root.path])
                let version = try first.readPage("file").version
                let held = expectation(description: "writer A owns gate")
                let suspension = FileSuspension("prepared", entered: held)
                defer { suspension.release() }
                first.hooks.onEvent = { try suspension.visit($0) }
                let writerA = Task.detached { [first] in
                    try first.write("file", content: "first", expectedVersion: version)
                }
                await fulfillment(of: [held], timeout: 10)
                let waiting = expectation(description: "B is waiting for occupied gate")
                let completed = expectation(description: "cancelled B joined before A release")
                let state = FileEventState()
                var second = AskFileTools(roots: [root.path])
                second.hooks.onEvent = { event in
                    state.record(event)
                    if event == "gateWait" {
                        waiting.fulfill()
                    }
                }
                host.fileOperationHooks = second.hooks
                let request = try call("write", path: path, extra: path == "file"
                    ? ["content": "second", "expected_version": version] : ["content": "second"])
                let binding = dispatch == 2 ? try await host.approvalBinding(for: request, conversationId: "c") : nil
                let writerB = Task {
                    defer { completed.fulfill() }
                    do {
                        if let binding {
                            _ = try await host.executeApproved(
                                request,
                                conversationId: "c",
                                binding: binding,
                                authorize: {}
                            )
                        } else {
                            _ = try await host.execute(request, conversationId: "c")
                        }
                        XCTFail("Cancelled B must fail")
                    } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                }
                await fulfillment(of: [waiting], timeout: 10)
                writerB.cancel()
                await fulfillment(of: [completed], timeout: 5)
                XCTAssertEqual(state.count("accessor"), 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
                XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
                suspension.release()
                _ = try await writerA.value
                await writerB.value
                XCTAssertEqual(state.count("accessor"), 0)
                _ = try AskFileTools(roots: [root.path]).write("after", content: "ok")
            }
        }
    }

    func testDirectSynchronousTaskCancellationWhileGateWaits() async throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let held = expectation(description: "A holds gate")
        let suspension = FileSuspension("prepared", entered: held)
        defer { suspension.release() }
        var first = AskFileTools(roots: [root.path])
        first.hooks.onEvent = { try suspension.visit($0) }
        let writerA = Task.detached { [first] in try first.write("a", content: "a") }
        await fulfillment(of: [held], timeout: 10)
        let waiting = expectation(description: "direct B waits")
        let completed = expectation(description: "direct B finishes before A")
        var second = AskFileTools(roots: [root.path])
        second.hooks.onEvent = {
            if $0 == "gateWait" {
                waiting.fulfill()
            }
        }
        let writerB = Task.detached { [second] in
            defer { completed.fulfill() }
            do { _ = try second.write("b", content: "b"); XCTFail("Must cancel") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [waiting], timeout: 10)
        writerB.cancel()
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b").path))
        suspension.release()
        _ = try await writerA.value
        await writerB.value
    }

    private func holdEditor(_ target: URL, suspension: FileSuspension) -> Task<Void, Error> {
        Task.detached {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var failure: NSError?
            var result: Result<Void, Error>?
            coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &failure) { _ in
                result = Result { try suspension.visit("editor") }
            }
            if let failure {
                throw failure
            }
            try XCTUnwrap(result).get()
        }
    }

    func testCancelledCoordinationWaitJoinsBeforeEditorRelease() async throws {
        for dispatch in 0 ... 2 {
            let (root, host, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let waiting = expectation(description: "Foundation asks editor A to relinquish for B")
            let completed = expectation(description: "B joined before editor release")
            let presenter = HeldFilePresenter(url: root.appendingPathComponent("file"), requested: waiting)
            NSFileCoordinator.addFilePresenter(presenter)
            defer {
                presenter.release()
                NSFileCoordinator.removeFilePresenter(presenter)
            }
            let state = FileEventState()
            var files = AskFileTools(roots: [root.path])
            let version = try files.readPage("file").version
            files.hooks.onEvent = { state.record($0) }
            host.fileOperationHooks = files.hooks
            let request = try call("write", extra: ["content": "new", "expected_version": version])
            let binding = dispatch == 2 ? try await host.approvalBinding(for: request, conversationId: "c") : nil
            let direct = dispatch == 0 ? Task.detached { [files] in
                defer { completed.fulfill() }
                do { _ = try files.write("file", content: "new", expectedVersion: version); XCTFail("Must cancel") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            } : nil
            let owner = dispatch != 0 ? Task {
                defer { completed.fulfill() }
                do {
                    if let binding {
                        _ = try await host.executeApproved(
                            request,
                            conversationId: "c",
                            binding: binding,
                            authorize: {}
                        )
                    } else {
                        _ = try await host.execute(request, conversationId: "c")
                    }
                    XCTFail("Must cancel")
                } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            } : nil
            await fulfillment(of: [waiting], timeout: 10)
            direct?.cancel(); owner?.cancel()
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(state.count("accessor"), 0)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
            presenter.release()
            NSFileCoordinator.removeFilePresenter(presenter)
            await direct?.value; await owner?.value
            XCTAssertEqual(state.count("accessor"), 0)
            _ = try AskFileTools(roots: [root.path]).write("file", content: "after", expectedVersion: version)
        }
    }

    func testHostCancellationBeforeCoordinatorRegistrationHasNoEffects() async throws {
        for approved in [false, true] {
            let (root, host, _) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let request = try call("write", path: "new/nested/file", extra: ["content": "new"])
            let binding = approved ? try await host.approvalBinding(for: request, conversationId: "c") : nil
            let entered = expectation(description: "before registration")
            let suspension = FileSuspension("beforeCoordinatorRegistration", entered: entered)
            defer { suspension.release() }
            host.fileOperationHooks.onEvent = { try suspension.visit($0) }
            let owner = Task {
                if let binding {
                    return try await host.executeApproved(request, conversationId: "c", binding: binding, authorize: {})
                }
                return try await host.execute(request, conversationId: "c")
            }
            await fulfillment(of: [entered], timeout: 10)
            owner.cancel(); suspension.release()
            do { _ = try await owner.value; XCTFail("Must cancel before registration") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
            _ = try AskFileTools(roots: [root.path]).write("after", content: "ok")
        }
        let controller = AskFileCancellation()
        controller.cancel()
        XCTAssertThrowsError(try controller.register(NSFileCoordinator(filePresenter: nil))) {
            XCTAssertTrue($0 is CancellationError)
        }
        controller.unregister()
    }

    func testRevokedGrantPrecedesEveryPreparationBoundary() async throws {
        let (root, host, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var files = AskFileTools(roots: [root.path])
        files.hooks.validateGrant = { throw AskFileAccess.denied }
        XCTAssertThrowsError(try files.write("new/nested/file", content: "new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        // The trusted host's injected validator must run before preparation too.
        host.fileOperationHooks = files.hooks
        for approved in [false, true] {
            let request = try call("write", path: "new/nested/file", extra: ["content": "new"])
            let binding = approved ? try await host.approvalBinding(for: request, conversationId: "c") : nil
            do {
                if let binding {
                    _ = try await host.executeApproved(request, conversationId: "c", binding: binding, authorize: {})
                } else {
                    _ = try await host.execute(request, conversationId: "c")
                }
                XCTFail("Already revoked authority must be refused")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        }
        for boundary in ["createParent", "createStaging"] {
            let state = FileEventState()
            files.hooks.validateGrant = { try state.validate() }
            files.hooks.onEvent = { event in
                if event == boundary {
                    state.revoke()
                }
            }
            XCTAssertThrowsError(try files.write("new/nested/file", content: "new"))
            if boundary == "createParent" {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
            } else {
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new/nested").path))
                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("new/nested").path),
                    []
                )
            }
        }
        _ = try AskFileTools(roots: [root.path]).write("new/nested/file", content: "authorized")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new/nested/file")), "authorized")
    }

    func testRevokedGrantAfterGateOrCoordinationWaitCreatesNoParents() async throws {
        for coordination in [false, true] {
            for approved in [false, true] {
                let (root, host, defaults) = try fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                let request = try call("write", path: "new/nested/file", extra: ["content": "new"])
                let binding = approved ? try await host.approvalBinding(for: request, conversationId: "c") : nil
                let held = expectation(description: "A held")
                let suspension = FileSuspension(coordination ? "editor" : "prepared", entered: held)
                defer { suspension.release() }
                let first: Task<Void, Error>
                if coordination {
                    first = holdEditor(root.appendingPathComponent("new/nested/file"), suspension: suspension)
                } else {
                    var files = AskFileTools(roots: [root.path])
                    files.hooks.onEvent = { try suspension.visit($0) }
                    first = Task.detached { [files] in _ = try files.write("a", content: "a") }
                }
                await fulfillment(of: [held], timeout: 10)
                let waiting = expectation(description: "B queued")
                host.fileOperationHooks.onEvent = {
                    if $0 == (coordination ? "coordinationWait" : "gateWait") {
                        waiting.fulfill()
                    }
                }
                let owner = Task {
                    if let binding {
                        return try await host.executeApproved(
                            request,
                            conversationId: "c",
                            binding: binding,
                            authorize: {}
                        )
                    }
                    return try await host.execute(request, conversationId: "c")
                }
                await fulfillment(of: [waiting], timeout: 10)
                defaults.set([], forKey: "ask.fileAccessFolders")
                suspension.release()
                try await first.value
                do { _ = try await owner.value; XCTFail("Queued authority must be revalidated") } catch {}
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
            }
        }
    }
}
