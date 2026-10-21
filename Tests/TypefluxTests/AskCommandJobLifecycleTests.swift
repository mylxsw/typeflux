import Foundation
import Testing
@testable import Typeflux

@Suite("Command job model lifecycle", .exclusiveUIState)
@MainActor
struct AskCommandJobLifecycleTests {
    private func makeTools(_ store: AskCommandJobStore, defaults: UserDefaults) -> AskLocalTools {
        let settings = SettingsStore(defaults: defaults)
        settings.askCodeExecutionEnabled = true
        return AskLocalTools(
            registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: defaults)),
            settings: settings,
            commandJobs: store,
            owner: { "owner" }
        )
    }

    @Test(arguments: [false, true])
    func `original run receipt survives response loss and natural settlement`(responseLost: Bool) async throws {
        let gate = AskCommandJobTests.Gate(), count = AskCommandJobTests.Count()
        var hooks = AskCommandJobStore.Hooks()
        hooks.run = { request in
            count.increment(); request.onStarted?(); await gate.wait()
            return .init(
                termination: Task.isCancelled ? .cancelled : .exited(0),
                exitCode: 0,
                stdout: "",
                stderr: "",
                outputTruncated: false
            )
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AskCommandJobStore(root: root, hooks: hooks)
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let tools = makeTools(store, defaults: defaults)
        let fixture = try AskTestFixture(defaults: defaults, toolsOverride: tools)
        defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.api.setFailReceipts(responseLost)
        await fixture.api.setTool(.init(
            id: "job-call",
            function: .init(name: "command_job", arguments: #"{"action":"start","command":"printf ok"}"#)
        ))
        fixture.model.launcherDraft.text = "Run a controlled command"
        fixture.model.submitLauncher()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        let conversation = try #require(fixture.model.selectedId)
        fixture.model.approve(conversationId: conversation, allowed: true)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        let journal = try await fixture.cache.executions(conversationId: conversation, owner: "owner")
        let entry = try #require(journal.first { $0.audit?.toolName == "command_job" })
        guard case let .tool(receipt) = entry.receipt
        else { Issue.record("Missing start receipt"); await gate.release(); await store.shutdown(); return }
        let status = try JSONDecoder().decode(AskCommandJobStore.Status.self, from: Data(receipt.content.utf8))
        #expect(status.state == "starting")
        #expect(receipt.runId == entry.audit?.identity.runId)
        #expect(receipt.toolCallId == "job-call")
        #expect(receipt.harness?.outcome?.status == "ok")
        #expect(receipt.harness?.outcome?.effectVerified == false)
        let scope = try tools.commandScope(conversation)
        if responseLost {
            // Receipt is journaled even though transport lost its response. Re-delivery
            // uses that evidence rather than launching the command a second time.
            #expect(!entry.unknown)
            await fixture.api.setFailReceipts(false)
            await fixture.model.retransmitSavedReceipts()
        }
        await gate.release(); await store.waitForCompletion(status.jobId)
        #expect(count.count <= 1)
        #expect(try store.status(status.jobId, scope: scope).state == "cancelled")
        await store.shutdown()
    }

    @Test(arguments: [false, true])
    func `logout and offline Stop keep original run evidence after restart`(offlineStop: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("job-reset-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = AskCommandJobTests.Count()
        var clock = Date(), hooks = AskCommandJobStore.Hooks()
        hooks.now = { clock }
        hooks.run = { request in
            count.increment(); request.onStarted?()
            return .init(termination: .exited(0), exitCode: 0, stdout: "", stderr: "", outputTruncated: false)
        }
        let defaults = try #require(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        weak var previousStore: AskCommandJobStore?
        func completeAndCancel() async throws -> (String, String) {
            let store = try AskCommandJobStore(root: root, hooks: hooks)
            previousStore = store
            let tools = makeTools(store, defaults: defaults)
            let fixture = try AskTestFixture(defaults: defaults, toolsOverride: tools)
            defer { fixture.model.resetSession(); try? FileManager.default.removeItem(at: fixture.root) }
            // Seed an already observed active run without starting an unrelated drive/title task.
            fixture.model.owner = "owner"
            var value = AskRecoveryFixture.conversation()
            let run = "active-run"
            value.run?.id = run; value.run?.status = "running"; value.run?.pending = []
            try await fixture.model.accept(value, route: .init(account: "owner", owner: "owner", token: "token"))
            tools.bindExecution(ownerId: "owner", conversationId: value.id, runId: run,
                                deviceId: "device", persistent: true)
            let scope = try tools.commandScope(value.id)
            let original = try await store.start(.init(action: "start", command: "printf ok"), scope: scope,
                                                 invocationID: "call", deadline: nil, workspace: { nil }, authorize: {})
            await store.waitForCompletion(original.jobId)
            if offlineStop {
                await fixture.api.failGet(value.id)
                fixture.model.stop(id: value.id)
                // Verify local cancellation immediately, independently of the failed network request.
            } else {
                fixture.model.resetSession()
            }
            do {
                _ = try await store.start(.init(action: "start", command: "printf ok"), scope: scope,
                                          invocationID: "new", deadline: nil, workspace: { nil }, authorize: {})
                Issue.record("Local cancellation must immediately revoke admission")
            } catch AskCommandJobError.unavailable {}
            await store.shutdown()
            return (value.id, run)
        }
        let (conversation, run) = try await completeAndCancel()
        // Stop's error reporting can still be finishing its asynchronous cache read.
        // Observe actual reference release before reopening the exclusively locked store.
        for _ in 0 ..< 1000 {
            if previousStore == nil { break }
            await Task.yield()
        }
        try #require(previousStore == nil)
        clock = clock.addingTimeInterval(86401)
        let reopened = try AskCommandJobStore(root: root, hooks: hooks)
        let scope = reopened.bind(owner: "owner", conversation: conversation, run: run,
                                  device: "device", persistent: true)
        do {
            _ = try await reopened.start(.init(action: "start", command: "printf ok"), scope: scope,
                                         invocationID: "call", deadline: nil, workspace: { nil }, authorize: {})
            Issue.record("Local cancellation must not permit replay after restart")
        } catch AskCommandJobError.unavailable {}
        do {
            _ = try await reopened.start(.init(action: "start", command: "different"), scope: scope,
                                         invocationID: "call", deadline: nil, workspace: { nil }, authorize: {})
            Issue.record("Changed arguments must still conflict")
        } catch AskCommandJobError.conflict {}
        #expect(count.count == 1)
        await reopened.shutdown()
    }

    @Test func `observer only settlement cannot cancel replacement run`() async throws {
        let gate = AskCommandJobTests.Gate()
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
        let store = try AskCommandJobStore(root: nil, hooks: hooks)
        let defaults = UserDefaults(suiteName: "job-observer-" + UUID().uuidString)!
        let tools = makeTools(store, defaults: defaults)
        let fixture = try AskTestFixture(defaults: defaults, toolsOverride: tools)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft.text = "Initialize session"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        var value = try #require(fixture.model.selected)
        tools.bindExecution(
            ownerId: "owner",
            conversationId: value.id,
            runId: "new",
            deviceId: "device",
            persistent: false
        )
        let scope = try tools.commandScope(value.id)
        let status = try await store.start(
            .init(action: "start", command: "printf ok"),
            scope: scope,
            invocationID: "new-call",
            deadline: nil,
            workspace: { nil },
            authorize: {}
        )
        // A late explicit cancellation of an older admitted run cannot cancel the replacement.
        tools.cancelProjectRun(.init(ownerId: "owner", conversationId: value.id, runId: "old"))
        tools.observeCommandRun(ownerId: "owner", conversationId: value.id, runId: "old", active: false)
        tools.observeCommandRun(ownerId: "other", conversationId: value.id, runId: nil, active: false)
        tools.observeCommandRun(ownerId: "owner", conversationId: value.id, runId: nil, active: true)
        #expect(try store.status(status.jobId, scope: scope).state != "stopping")
        value.run?.id = "new"; value.run?.status = "completed"; value.revision += 10
        let route = AskRoute(account: "owner", owner: "owner", token: "token")
        try await fixture.model.accept(value, route: route)
        await gate.release(); await store.waitForCompletion(status.jobId)
        #expect(try store.status(status.jobId, scope: scope).state == "cancelled")
        await store.shutdown()
    }
}
