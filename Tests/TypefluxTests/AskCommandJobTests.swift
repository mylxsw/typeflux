import Darwin
import Foundation
@testable import Typeflux
import XCTest

@MainActor
final class AskCommandJobTests: XCTestCase {
    actor Gate {
        var open = false
        var continuations: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open {
                return
            }
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            open = true; let pending = continuations; continuations = []; pending.forEach { $0.resume() }
        }
    }

    final class Count: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
        func increment() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    private var roots: [URL] = []
    private func root() -> URL {
        let value = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-job-tests-" + UUID().uuidString)
        roots.append(value); return value
    }

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func bind(
        _ store: AskCommandJobStore,
        owner: String = "owner",
        conversation: String = "chat",
        run: String = "run",
        device: String = "device",
        persistent: Bool = false
    ) -> AskCommandJobScope {
        store.bind(owner: owner, conversation: conversation, run: run, device: device, persistent: persistent)
    }

    private func start(
        _ store: AskCommandJobStore,
        _ scope: AskCommandJobScope,
        command: String = "printf ok",
        id: String = "call",
        timeout: Int = 5,
        deadline: Date? = nil
    ) async throws -> AskCommandJobStore.Status {
        try await store.start(
            .init(action: "start", command: command, timeout: timeout),
            scope: scope,
            invocationID: id,
            deadline: deadline,
            workspace: { nil },
            authorize: {}
        )
    }

    private func call(_ args: [String: Any], id: String = "call") throws -> AskToolCall {
        try .init(
            id: id,
            function: .init(
                name: "command_job",
                arguments: String(decoding: JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            )
        )
    }

    func testStrictValidationAndRecoveryRisk() throws {
        let handle = UUID().uuidString.lowercased()
        for args: [String: Any] in [
            [:], ["action": "bogus"], ["action": "start", "command": ""],
            ["action": "start", "command": String(repeating: "界", count: 401)],
            ["action": "start", "command": "x\0"], ["action": "start", "command": "ok", "stdin": "x"],
            ["action": "start", "command": "ok", "timeout_seconds": true],
            ["action": "start", "command": "ok", "timeout_seconds": 0],
            ["action": "start", "command": "ok", "timeout_seconds": 601],
            ["action": "start", "command": "ok", "timeout_seconds": 1.5],
            ["action": "start", "command": "ok", "timeout_seconds": "3"],
            ["action": "start", "command": "ok", "timeout_seconds": NSNull()],
            ["action": "status", "job_id": handle, "command": "x"], ["action": "status", "job_id": "bad"],
            ["action": "stop", "job_id": 2], ["action": "logs", "job_id": handle],
            ["action": "logs", "job_id": handle, "stream": "both"],
            ["action": "logs", "job_id": handle, "stream": "stdout", "offset": -1],
            ["action": "logs", "job_id": handle, "stream": "stdout", "limit": 16385]
        ] {
            XCTAssertThrowsError(try AskCommandJobRequest.validated(args))
        }
        XCTAssertEqual(try AskCommandJobRequest.validated(["action": "start", "command": "ok"]).timeout, 120)
        XCTAssertEqual(
            try AskCommandJobRequest.validated(["action": "logs", "job_id": handle, "stream": "stderr"]).limit,
            8192
        )
        for (action, risk, recovery) in [
            ("start", AskToolRisk.destructive, false),
            ("stop", .write, false),
            ("status", .read, true),
            ("logs", .read, true)
        ] {
            let tool = try call(["action": action, "job_id": handle])
            XCTAssertEqual(AskLocalTools.builtinRisk(tool), risk)
            XCTAssertEqual(AskRecoveryObservation.permits(tool), recovery)
        }
        XCTAssertEqual(AskRecoveryObservation.offered([AskCommandJobRequest.definition]).count, 1)
    }

    func testRealExcessOutputDrainsBothStreamsAndPreservesExitAndMarker() async throws {
        let directory = root()
        let store = try AskCommandJobStore(root: nil), scope = bind(store)
        for code in [0, 7] {
            let status = try await store.start(.init(action: "start",
                                                     command:
                                                     "head -c 90000 /dev/zero | tr '\\000' x; head -c 80000 /dev/zero >&2; printf done > marker; exit \(code)",
                                                     timeout: 10),
                                               scope: scope,
                                               invocationID: "exit-\(code)",
                                               deadline: nil,
                                               workspace: {
                                                   _ = try AskSecureDirectory.openRoot(directory); return directory
                                               },
                                               authorize: {})
            XCTAssertEqual(status.state, "starting")
            XCTAssertFalse(status.outcomeAmbiguous)
            XCTAssertTrue(status.lifetime.contains("run completion"))
            await store.waitForCompletion(status.jobId)
            let done = try store.status(status.jobId, scope: scope)
            XCTAssertEqual(done.state, "exited"); XCTAssertEqual(done.exitCode,
                                                                 Int32(code)); XCTAssertFalse(done.outcomeAmbiguous)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("marker")), "done")
            let out = try store.logs(status.jobId, scope: scope, stream: .stdout, offset: 65530, limit: 8192)
            XCTAssertEqual(out.text, "xxxxxx"); XCTAssertEqual(out.retainedBytes, 65536)
            XCTAssertEqual(out.nextOffset, 65536); XCTAssertEqual(out.omittedBytes,
                                                                  24464); XCTAssertTrue(out.incomplete)
            let err = try store.logs(status.jobId, scope: scope, stream: .stderr, offset: 0, limit: 16384)
            XCTAssertEqual(err.retainedBytes, 65536); XCTAssertEqual(err.omittedBytes, 14464)
            XCTAssertEqual(err.text.utf8.count, 16384)
            let beyond = try store.logs(status.jobId, scope: scope, stream: .stdout, offset: Int.max, limit: 1)
            XCTAssertEqual(beyond.text, ""); XCTAssertEqual(beyond.nextOffset, 65536)
        }
        await store.shutdown()
    }

    func testLiveChunksUTF8OffsetsStopAndRetransmission() async throws {
        let gate = Gate(), started = Gate(), count = Count()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { request in
            count.increment(); request.onStarted?()
            request.onRawOutput?(.stdout, Data([0xF0, 0x9F, 0x8C, 0x8D, 0xFF, 65]))
            request.onRawOutput?(.stderr, Data(repeating: 66, count: 8192))
            await started.release(); await gate.wait()
            return .init(
                termination: Task.isCancelled ? .cancelled : .exited(0),
                exitCode: 0,
                stdout: "",
                stderr: "",
                outputTruncated: false
            )
        }
        let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
        let first = try await start(store, scope)
        await started.wait()
        let duplicate = try await start(store, scope)
        XCTAssertEqual(first.jobId, duplicate.jobId); XCTAssertEqual(count.count, 1)
        do { _ = try await start(store, scope, command: "other"); XCTFail("Expected rejection")
        } catch AskCommandJobError.conflict {}
        XCTAssertEqual(try store.status(first.jobId, scope: scope).state, "running")
        for offset in 0 ..< 6 {
            let page = try store.logs(first.jobId, scope: scope, stream: .stdout, offset: offset, limit: 1)
            XCTAssertEqual(page.nextOffset,
                           offset + 1); XCTAssertFalse(page.text.isEmpty); XCTAssertTrue(page.incomplete)
        }
        XCTAssertEqual(try store.logs(first.jobId, scope: scope, stream: .stderr, offset: 0, limit: 2).text, "BB")
        XCTAssertEqual(try store.stop(first.jobId, scope: scope).state, "stopping")
        XCTAssertEqual(try store.stop(first.jobId, scope: scope).state, "stopping")
        await gate.release(); await store.waitForCompletion(first.jobId)
        XCTAssertEqual(try store.stop(first.jobId, scope: scope).state, "cancelled")
        XCTAssertEqual(count.count, 1)
        await store.shutdown()
    }

    func testAtomicCapacityAndNewRunCancelsWithoutAdoption() async throws {
        let gate = Gate()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { request in
            request.onStarted?(); await gate.wait()
            return .init(
                termination: Task.isCancelled ? .cancelled : .exited(0),
                exitCode: 0,
                stdout: "",
                stderr: "",
                outputTruncated: false
            )
        }
        let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
        let one = try await start(store, scope, id: "one"), two = try await start(store, scope, id: "two")
        do { _ = try await start(store, scope, id: "three"); XCTFail("Expected rejection") } catch AskCommandJobError
            .capacity {}
        let second = bind(store, conversation: "second")
        _ = try await start(store, second, id: "one"); _ = try await start(store, second, id: "two")
        let third = bind(store, conversation: "third")
        do { _ = try await start(store, third); XCTFail("Expected rejection") } catch AskCommandJobError.capacity {}
        let replacement = bind(store, run: "replacement")
        XCTAssertThrowsError(try store.status(one.jobId, scope: replacement))
        XCTAssertThrowsError(try store.stop(two.jobId, scope: scope))
        await gate.release(); await store.waitForCompletion(one.jobId)
        XCTAssertEqual(try store.status(one.jobId, scope: replacement).state, "cancelled")
        let otherDevice = bind(store, run: "another", device: "other")
        XCTAssertThrowsError(try store.status(one.jobId, scope: otherDevice))
        let otherOwner = bind(store, owner: "other")
        XCTAssertThrowsError(try store.status(one.jobId, scope: otherOwner))
        await store.shutdown()
    }

    func testHeldWorkspaceRevalidatesAndImmediateCancellationNeverSpawns() async throws {
        let gate = Gate(), preparing = Gate(), count = Count()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { _ in count.increment(); throw CancellationError() }
        let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
        let task = Task { try await store.start(
            .init(action: "start", command: "touch never"),
            scope: scope,
            invocationID: "held",
            deadline: nil,
            workspace: { await preparing.release(); await gate.wait(); return nil },
            authorize: {}
        ) }
        await preparing.wait(); store.cancelRun(scope); await gate.release()
        do { _ = try await task.value; XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(count.count, 0)
        let next = bind(store, run: "next")
        let status = try await start(store, next)
        _ = try store.stop(status.jobId, scope: next) // Cancel before the installed task can run.
        await store.waitForCompletion(status.jobId)
        XCTAssertEqual(count.count, 0)
        XCTAssertEqual(try store.status(status.jobId, scope: next).state, "cancelled")
        XCTAssertFalse(try store.status(status.jobId, scope: next).outcomeAmbiguous)
        do { _ = try await start(store, next, id: "late", deadline: .distantPast); XCTFail("Expected rejection")
        } catch {}
        await store.shutdown()
    }

    func testPersistenceRestartInterruptedPrivacyCorruptionAndDiskFailure() async throws {
        let directory = root(), secure = try AskSecureDirectory.openRoot(directory)
        let handle = UUID().uuidString.lowercased()
        var record = AskCommandJobStore.Record(
            handle: handle,
            owner: "owner",
            conversation: "chat",
            run: "old",
            device: "device",
            invocation: "call",
            digest: "digest",
            created: Date(),
            updated: Date()
        )
        record.stdout.prefix = Data("historical".utf8)
        try secure.createFile(handle + ".json", data: JSONEncoder().encode(record))
        let unknown = UUID().uuidString.lowercased() + ".json"
        record.version = 99
        try secure.createFile(unknown, data: JSONEncoder().encode(record))
        try secure.createFile(UUID().uuidString.lowercased() + ".json", data: Data("bad".utf8))
        let store = try AskCommandJobStore(root: directory), scope = bind(store, persistent: true)
        XCTAssertThrowsError(try AskCommandJobStore(root: directory)) // Exclusive instance lock.
        let status = try store.status(handle, scope: scope)
        XCTAssertEqual(status.state, "interrupted"); XCTAssertTrue(status.outcomeAmbiguous)
        XCTAssertEqual(try store.logs(handle, scope: scope, stream: .stdout, offset: 0, limit: 20).text, "historical")
        XCTAssertEqual(try store.stop(handle, scope: scope).state, "interrupted")
        XCTAssertEqual(try secure.readFile(unknown, limit: 196_608), try JSONEncoder().encode(record))
        try store.cancelConversation(owner: "owner", conversation: "chat")
        XCTAssertThrowsError(try store.status(handle, scope: scope))
        await store.shutdown()
        let count = Count(); var hooks = AskCommandJobStore.Hooks()
        hooks.beforePersist = { throw AskCommandJobError.storage }
        hooks.run = { _ in count.increment(); throw CancellationError() }
        let failing = try AskCommandJobStore(root: root(), hooks: hooks), live = bind(failing, persistent: true)
        do { _ = try await start(failing, live); XCTFail("Expected rejection") } catch {}
        XCTAssertEqual(count.count, 0)
        await failing.shutdown()
    }
}

extension AskCommandJobTests {
    func testTemporaryRecordsStayInMemoryAndPurgeRejectsLateOutput() async throws {
        let directory = root(), gate = Gate(), started = Gate()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { request in
            request.onStarted?(); await started.release(); await gate.wait()
            request.onRawOutput?(.stdout, Data("late".utf8))
            return .init(termination: .cancelled, exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        }
        let store = try AskCommandJobStore(root: directory, hooks: hooks), scope = bind(store)
        let status = try await start(store, scope)
        await started.wait()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        try store.cancelConversation(owner: scope.owner, conversation: scope.conversation)
        await gate.release(); await store.shutdown()
        XCTAssertThrowsError(try store.status(status.jobId, scope: scope))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testApprovedToolDefaultFlowDisabledSettingAndFreshBinding() async throws {
        let defaults = UserDefaults(suiteName: "command-job-tools-" + UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        settings.askCodeExecutionEnabled = true
        let store = try AskCommandJobStore(root: nil)
        let tools = AskLocalTools(
            registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
            settings: settings,
            commandJobs: store,
            owner: { "owner" }
        )
        tools.bindExecution(
            ownerId: "owner",
            conversationId: "chat",
            runId: "run",
            deviceId: "device",
            persistent: false
        )
        let definitions = await tools.definitions(conversationId: "chat")
        XCTAssertTrue(definitions.contains { $0.name == "command_job" })
        XCTAssertFalse(definitions.contains { $0.name == "project_terminal" })
        let invocation = try call(["action": "start", "command": "printf ok"])
        do { _ = try await tools.execute(invocation, conversationId: "chat"); XCTFail("Expected rejection") } catch {}
        let binding = try await tools.approvalBinding(for: invocation, conversationId: "chat")
        XCTAssertFalse(binding.allowsReuse)
        var checks = 0
        let output = try await tools.executeApproved(
            invocation,
            conversationId: "chat",
            binding: binding,
            authorize: { checks += 1 }
        )
        let status = try JSONDecoder().decode(AskCommandJobStore.Status.self, from: Data(output.content.utf8))
        XCTAssertGreaterThanOrEqual(checks, 3); XCTAssertEqual(output.outcome?.effectVerified, false)
        await store.waitForCompletion(status.jobId)
        settings.askCodeExecutionEnabled = false
        let disabled = await tools.definitions(conversationId: "chat")
        let jobDefinition = try XCTUnwrap(disabled.first { $0.name == "command_job" })
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: jobDefinition.parameters.data) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["action"]?["enum"] as? [String], ["status", "logs", "stop"])
        do {
            _ = try await tools.approvalBinding(for: invocation, conversationId: "chat"); XCTFail("Expected rejection")
        } catch {}
        for action in ["status", "logs", "stop"] {
            var args: [String: Any] = ["action": action, "job_id": status.jobId]
            if action == "logs" {
                args["stream"] = "stdout"
            }
            let read = try call(args, id: action), binding = try await tools.approvalBinding(
                for: read,
                conversationId: "chat"
            )
            _ = try await tools.executeApproved(read, conversationId: "chat", binding: binding, authorize: {})
        }
        try tools.deleteArtifacts(ownerId: "owner", conversationId: "chat")
        await tools.shutdownCommandJobs()
    }

    func testTerminalPersistenceFailureKeepsEvidenceAndLaunchFailureIsNotRetried() async throws {
        var writes = 0
        var hooks = AskCommandJobStore.Hooks()
        hooks.beforePersist = {
            writes += 1; if writes > 1 {
                throw AskCommandJobError.storage
            }
        }
        let store = try AskCommandJobStore(root: root(), hooks: hooks), scope = bind(store, persistent: true)
        let first = try await start(store, scope)
        await store.waitForCompletion(first.jobId)
        let status = try store.status(first.jobId, scope: scope)
        XCTAssertEqual(status.state, "exited"); XCTAssertFalse(status.durabilityAvailable)
        let repeated = try await start(store, scope)
        XCTAssertEqual(repeated.jobId, first.jobId)
        await store.shutdown()
        let count = Count()
        hooks = .init(); hooks.run = { _ in count.increment(); throw AskCommandJobError.unavailable }
        let failing = try AskCommandJobStore(root: nil, hooks: hooks), live = bind(failing)
        let failed = try await start(failing, live)
        await failing.waitForCompletion(failed.jobId)
        XCTAssertEqual(try failing.status(failed.jobId, scope: live).state, "failed_to_start")
        let duplicate = try await start(failing, live)
        XCTAssertEqual(duplicate.jobId, failed.jobId); XCTAssertEqual(count.count, 1)
        await failing.shutdown()
    }

    func testRetentionBoundsExpiryAndNoHistoricalReplay() async throws {
        let directory = root(), secure = try AskSecureDirectory.openRoot(directory), now = Date()
        var oldest = ""
        for index in 0 ..< 132 {
            let handle = UUID().uuidString.lowercased()
            if index == 0 {
                oldest = handle
            }
            var record = AskCommandJobStore.Record(
                handle: handle,
                owner: "owner",
                conversation: "chat",
                run: "old",
                device: "device",
                invocation: String(index),
                digest: "digest",
                created: now,
                updated: now.addingTimeInterval(Double(index))
            )
            record.state = .exited; record.exitCode = 0
            try secure.createFile(handle + ".json", data: JSONEncoder().encode(record))
        }
        var clock = now
        var hooks = AskCommandJobStore.Hooks(); hooks.now = { clock }
        let store = try AskCommandJobStore(root: directory, hooks: hooks), scope = bind(store, persistent: true)
        XCTAssertEqual(secure.entries().count, 128)
        XCTAssertThrowsError(try store.status(oldest, scope: scope))
        clock = now.addingTimeInterval(90000)
        XCTAssertThrowsError(try store.status(UUID().uuidString.lowercased(), scope: scope))
        XCTAssertEqual(secure.entries().count, 0)
        await store.shutdown()
    }

    func testRevokedAdmissionAndBoundedBufferNeverReopens() async throws {
        let buffer = AskCommandJobBuffer()
        for _ in 0 ..< 20 {
            buffer.append(.stdout, Data(repeating: 65, count: 8192))
        }
        buffer.markStarted(); buffer.close(); buffer.append(.stdout, Data([66]))
        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.stdout.prefix.count, 65536); XCTAssertEqual(snapshot.stdout.omitted, 98304)
        let count = Count(); var hooks = AskCommandJobStore.Hooks()
        hooks.run = { _ in count.increment(); throw CancellationError() }
        let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
        let status = try await store.start(
            .init(action: "start", command: "printf ok"),
            scope: scope,
            invocationID: "admission",
            deadline: nil,
            workspace: { nil },
            authorize: {},
            admission: { throw AskCommandJobError.unavailable }
        )
        await store.waitForCompletion(status.jobId)
        XCTAssertEqual(count.count, 0)
        XCTAssertEqual(try store.status(status.jobId, scope: scope).state, "failed_to_start")
        await store.shutdown()
    }

    func testRealNoisyDeadlineAndSignalRemainAmbiguous() async throws {
        let store = try AskCommandJobStore(root: nil), scope = bind(store)
        let noisy = try await start(store, scope, command: "while :; do printf '%8192s' x; printf '%8192s' y >&2; done",
                                    timeout: 1, deadline: Date().addingTimeInterval(0.1))
        await store.waitForCompletion(noisy.jobId)
        XCTAssertEqual(try store.status(noisy.jobId, scope: scope).state, "timed_out")
        XCTAssertTrue(try store.status(noisy.jobId, scope: scope).outcomeAmbiguous)
        let signal = try await start(store, scope, command: "kill -KILL $$", id: "signal")
        await store.waitForCompletion(signal.jobId)
        XCTAssertEqual(try store.status(signal.jobId, scope: scope).state, "interrupted")
        XCTAssertTrue(try store.status(signal.jobId, scope: scope).outcomeAmbiguous)
        await store.shutdown()
    }

    func testRealLiveGiantLinesOnBothStreamsStopCleansGroup() async throws {
        let directory = root()
        _ = try AskSecureDirectory.openRoot(directory)
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("control").path, 0o600), 0)
        let ready = expectation(description: "Both raw streams exceeded prefix while child still running")
        let count = Count()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { original in
            var request = original
            request.onRawOutput = { stream, data in
                original.onRawOutput?(stream, data)
                count.lock.withLock {
                    count.value += data.count
                    if count.value >= 140_000 {
                        ready.fulfill(); count.value = Int.min / 2
                    }
                }
            }
            return try await ManagedProcess().run(request)
        }
        let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
        let status = try await store.start(.init(action: "start",
                                                 command:
                                                 "echo $$ > pid; sleep 30 & echo $! > child; head -c 70000 /dev/zero; head -c 70000 /dev/zero >&2; cat < control",
                                                 timeout: 10),
                                           scope: scope, invocationID: "live", deadline: nil, workspace: { directory },
                                           authorize: {})
        await fulfillment(of: [ready], timeout: 5)
        for stream in [ManagedProcess.Stream.stdout, .stderr] {
            let logs = try store.logs(status.jobId, scope: scope, stream: stream, offset: 0, limit: 16384)
            XCTAssertEqual(logs.status.state, "running"); XCTAssertEqual(logs.retainedBytes, 65536)
            XCTAssertEqual(logs.omittedBytes, 4464); XCTAssertTrue(logs.incomplete)
        }
        XCTAssertEqual(try store.stop(status.jobId, scope: scope).state, "stopping")
        await store.waitForCompletion(status.jobId)
        XCTAssertEqual(try store.status(status.jobId, scope: scope).state, "cancelled")
        for name in ["pid", "child"] {
            let pid =
                try XCTUnwrap(Int32(String(contentsOf: directory.appendingPathComponent(name))
                            .trimmingCharacters(in: .whitespacesAndNewlines)))
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            XCTAssertTrue(size == 0 || info.pbi_status == SZOMB)
        }
        await store.shutdown()
    }

    func testHeldConcurrentRetransmissionAndRevokedAuthority() async throws {
        for revoke in [false, true] {
            let entered = Gate(), gate = Gate(), count = Count()
            var hooks = AskCommandJobStore.Hooks()
            hooks.run = { _ in count.increment(); return .init(
                termination: .exited(0),
                exitCode: 0,
                stdout: "",
                stderr: "",
                outputTruncated: false
            ) }
            let store = try AskCommandJobStore(root: nil, hooks: hooks), scope = bind(store)
            var allowed = true
            let first = Task {
                try await store.start(.init(action: "start", command: "printf ok"), scope: scope, invocationID: "same",
                                      deadline: nil,
                                      workspace: {
                                          await entered.release(); await gate.wait(); return nil
                                      },
                                      authorize: {
                                          if !allowed {
                                              throw AskCommandJobError.unavailable
                                          }
                                      })
            }
            await entered.wait()
            if revoke {
                allowed = false
            } else {
                let second = try await start(store, scope, id: "same", timeout: 120)
                XCTAssertEqual(second.state, "starting")
            }
            await gate.release()
            do {
                let result = try await first.value
                XCTAssertFalse(revoke)
                await store.waitForCompletion(result.jobId)
                XCTAssertEqual(count.count, 1)
            } catch { XCTAssertTrue(revoke); XCTAssertEqual(count.count, 0) }
            await store.shutdown()
        }
    }

    func testKnownExitWinsStopIntentAndFinalRecordReopensWithoutReplay() async throws {
        let gate = Gate(), entered = Gate(), directory = root(), count = Count()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { request in
            count.increment(); request.onStarted?(); request.onRawOutput?(.stdout, Data("done".utf8))
            await entered.release(); await gate.wait()
            // Simulate cleanup handing back an already observed normal exit.
            return .init(termination: .exited(7), exitCode: 7, stdout: "", stderr: "", outputTruncated: false)
        }
        var store: AskCommandJobStore? = try AskCommandJobStore(root: directory, hooks: hooks)
        let scope = try bind(XCTUnwrap(store), persistent: true)
        let status = try await start(XCTUnwrap(store), scope)
        await entered.wait()
        _ = try store?.stop(status.jobId, scope: scope)
        await gate.release(); await store?.waitForCompletion(status.jobId)
        XCTAssertEqual(try store?.status(status.jobId, scope: scope).state, "exited")
        XCTAssertFalse(try XCTUnwrap(store?.status(status.jobId, scope: scope).outcomeAmbiguous))
        await store?.shutdown(); store = nil
        let reopened = try AskCommandJobStore(root: directory, hooks: hooks), next = bind(
            reopened,
            run: "new",
            persistent: true
        )
        XCTAssertEqual(try reopened.status(status.jobId, scope: next).exitCode, 7)
        XCTAssertEqual(try reopened.logs(status.jobId, scope: next, stream: .stdout, offset: 0, limit: 10).text, "done")
        XCTAssertEqual(count.count, 1)
        await reopened.shutdown()
    }

    func testCommandApprovalCopyAndUserTitlesDoNotExposeHandles() throws {
        let invocation = try call(["action": "start", "command": "printf ok", "timeout_seconds": 10])
        let preview = AskApprovalPresentation.preview(invocation)
        XCTAssertEqual(
            preview,
            .content("printf ok\n\n" + L("ask.commandJob.deadline", 10) + "\n" + L("ask.commandJob.lifetime"))
        )
        XCTAssertTrue(AskApprovalCard.previewStartsExpanded(preview, call: invocation))
        XCTAssertEqual(AskApprovalCopy.question(invocation), L("ask.approval.q.command"))
        for action in ["status", "logs", "stop"] {
            let request = try call(["action": action, "job_id": UUID().uuidString.lowercased()])
            XCTAssertEqual(AskApprovalPresentation.preview(request), .none)
            XCTAssertEqual(AskTheme.toolTitle(request), L("ask.commandJob." + action))
        }
        for error in [AskCommandJobError.invalid, .unavailable, .capacity, .conflict, .storage] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
