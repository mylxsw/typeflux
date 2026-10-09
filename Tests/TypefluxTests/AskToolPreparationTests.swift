import Combine
import Foundation
import Testing
@testable import Typeflux

@Suite("Tool preparation failures", .serialized, .exclusiveUIState)
@MainActor
struct AskToolPreparationTests {
    @MainActor struct Fixture {
        let base: AskTestFixture
        let tools: AskLocalTools
        let runner: ObservationScriptRunner
        let desktop = AskComputerExecutorTests.Desktop()
        let model: AskConversationModel

        init() throws {
            base = try AskTestFixture()
            (tools, runner) = AskAutomationIntegrationTests()
                .tools(owner: { [state = base.sessionState] in state.owner })
            tools.computerEnvironment = { [desktop] _ in desktop.environment }
            model = AskConversationModel(api: base.api, cache: base.cache, tools: tools, capture: base.capture,
                                         deviceId: "device", modelLibrary: base.model.modelLibrary,
                                         session: { [state = base.sessionState] in (state.owner, "token") })
        }

        func open(_ call: AskToolCall) async {
            var value = AskRecoveryFixture.conversation()
            value.messages[0].createdAt = Date(timeIntervalSince1970: 1_800_000_000)
            value.run?.pending = [call]
            await base.api.seed(value)
            await model.select(value.id)
        }

        func close() {
            model.resetSession()
            base.model.resetSession()
            try? FileManager.default.removeItem(at: base.root)
        }
    }

    @Test(arguments: ["computer", "browser", "invalid-json", "missing-tool", "stale-observation", "permission"])
    func `rejected preparation settles pending call`(_ scenario: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        let name = ["invalid-json", "stale-observation", "permission"].contains(scenario) ? "computer" : scenario
        var args = #"{"action":"click","x":0.2,"y":0.2}"#
        if scenario == "invalid-json" {
            args = "{"
        }
        if scenario == "stale-observation" {
            f.tools.computerExecutor.writesEnabled = true
        }
        if scenario == "permission" {
            args = #"{"action":"inspect"}"#
            f.tools.computerEnvironment = { _ in .init(target: {
                throw AskLocalError.message(L("ask.tool.accessibility"))
            }, activate: {}, isActive: { true }) }
        }
        let call = AskToolCall(id: "call", function: .init(name: name, arguments: args))
        await f.open(call)
        f.model.resume()
        f.model.resume() // Repeated clicks while the operation is busy are ignored.
        try await f.base.wait { f.model.busyIds.isEmpty }
        #expect(f.model.error == nil)
        #expect(f.model.selected?.run?.status == "completed")
        #expect(f.model.selected?.run?.pending.isEmpty == true)
        #expect(f.model.pendingApprovals.isEmpty && !f.model.hasRecoveryNotice)
        let results = await f.base.api.results
        let result = try #require(results.first)
        #expect(results.count == 1 && result.isError)
        #expect(result.harness?.outcome?.status == (["computer", "browser"].contains(scenario) ? "denied" : "invalid"))
        #expect(result.harness?.outcome?.eventDispatched == false)
        #expect(result.harness?.context?.approvalId == nil)
        let entry = try #require(await f.base.cache.execution(id: "run/call", owner: "owner"))
        #expect(entry.acknowledged && !entry.unknown && entry.receipt == .tool(result))
        #expect(entry.audit?.approvalId == nil)
        #expect(f.desktop.events.isEmpty && f.runner.scripts.isEmpty)
        f.model.resume()
        try await f.base.wait { f.model.busyIds.isEmpty }
        #expect(await f.base.api.results.count == 1)
    }

    @Test(arguments: ["computer", "browser"])
    func `disabled actions are omitted and approval uses the effective definition`(_ name: String) async throws {
        let f = try Fixture()
        defer { f.close() }
        let call = AskToolCall(id: "read", function: .init(name: name,
                                                           arguments: name == "computer" ? #"{"action":"inspect"}"# :
                                                               #"{"action":"snapshot"}"#))
        for enabled in [false, true] {
            f.tools.computerExecutor.writesEnabled = enabled
            f.tools.browserExecutor.writesEnabled = enabled
            let definitions = await f.tools.definitions(conversationId: "c")
            let definition = try #require(definitions.first { $0.name == name })
            let json = try #require(JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any])
            let props = try #require(json["properties"] as? [String: [String: Any]])
            let actions = try #require(props["action"]?["enum"] as? [String])
            #expect(actions.contains("click") == enabled)
            if !enabled {
                #expect(actions == (name == "computer" ? ["screenshot", "inspect", "wait"] : [
                    "read",
                    "snapshot"
                ]))
            }
            let binding = try await f.tools.approvalBinding(for: call, conversationId: "c")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            #expect(try binding.toolVersion == AskToolPolicy.digest(encoder.encode(definition)))
        }
    }

    @Test func `failed delivery survives restart and only retransmits the receipt`() async throws {
        let f = try Fixture()
        defer { f.close() }
        await f.base.api.setFailReceipts(true)
        await f.open(.init(id: "call", function: .init(name: "computer", arguments: #"{"action":"click"}"#)))
        f.model.resume()
        try await f.base.wait { f.model.busyIds.isEmpty && f.model.canRetransmitReceipts }
        let saved = try #require(await f.base.cache.execution(id: "run/call", owner: "owner"))
        #expect(!saved.unknown && !saved.acknowledged && saved.receipt?.status == "denied")
        #expect(!f.model.recoveryPresentation.canContinue && f.model.recoveryPresentation.canEnd)
        f.model.resetSession()
        let reopened = try AskConversationModel(api: f.base.api,
                                                cache: AskConversationCache(url: f.base.root
                                                    .appendingPathComponent("cache.sqlite")),
                                                tools: f.tools, capture: f.base.capture, deviceId: "device",
                                                modelLibrary: f.base.model.modelLibrary,
                                                session: { ("owner", "token") })
        defer { reopened.resetSession() }
        f.tools.computerExecutor.writesEnabled = true
        await f.base.api.setFailReceipts(false)
        await reopened.select("conversation")
        #expect(reopened.canRetransmitReceipts)
        await reopened.retransmitSavedReceipts()
        #expect(reopened.selected?.run?.status == "completed" && !reopened.hasRecoveryNotice)
        #expect(await f.base.api.results.count == 1)
        #expect(try saved.receipt == .tool(#require(await f.base.api.results.first)))
        #expect(f.desktop.events.isEmpty && f.runner.scripts.isEmpty)
    }

    @Test(arguments: [2, 3])
    func `binding revalidation failure settles without dispatch`(_ failureAt: Int) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        await f.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        f.model.launcherDraft.text = "Read the page"
        f.model.setPermissionMode(.strict, launcher: true)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        var checks = 1
        f.tools.beforeBinding = {
            checks += 1
            if checks == failureAt { f.tools.bindingError = AskObservationError.needsObservation }
        }
        try f.model.approve(conversationId: #require(f.model.selectedId), allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 0)
        let result = try #require(await f.api.results.first)
        #expect(result.harness?.outcome?.status == "invalid")
        #expect(result.harness?.outcome?.eventDispatched == false)
        #expect(f.model.selected?.run?.status == "completed" && !f.model.hasRecoveryNotice)
    }

    @Test(arguments: ["cancel", "account", "new-run", "new-call"])
    func `preparation failure never settles obsolete work`(_ change: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let original = AskRecoveryFixture.conversation()
        await f.api.seed(original)
        await f.model.select(original.id)
        f.tools.bindingError = change == "cancel" ? CancellationError() : AskObservationError.disabled
        if change == "account" {
            f.tools.beforeBinding = { f.sessionState.owner = "other" }
        }
        if change == "new-run" || change == "new-call" {
            f.tools.beforeBindingAsync = {
                var latest = original
                if change == "new-run" {
                    latest.run?.id = "replacement"
                } else {
                    latest.run?.pending[0].id = "replacement"
                }
                latest.revision += 10
                try await f.model.accept(latest, route: #require(f.model.credentials(for: original.id)))
            }
        }
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.results.isEmpty)
        #expect(f.tools.executions == 0)
        #expect(try await f.cache.executions(conversationId: original.id, owner: "owner").isEmpty)
    }

    @Test func `unacknowledged unknown execution still requires inspection`() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.tools.fail = true
        await f.api.setFailReceipts(true)
        await f.api.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        f.model.launcherDraft.text = "Read"
        f.model.setPermissionMode(.strict, launcher: true)
        f.model.submitLauncher()
        try await f.wait { !f.model.pendingApprovals.isEmpty }
        let id = try #require(f.model.selectedId)
        // Sample the journal the instant the conversation stops being busy: a failed run must
        // not look idle and resumable before its unknown execution is visible.
        var statusWhenIdle: [String?] = []
        let observation = f.model.$busyIds.dropFirst().sink { [model = f.model] busy in
            if !busy.contains(id) { statusWhenIdle.append(model.selectedRecoveryEntries.first?.receipt?.status) }
        }
        defer { observation.cancel() }
        f.model.approve(conversationId: id, allowed: true)
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(statusWhenIdle == ["unknown"])
        #expect(await f.api.results.isEmpty)
        #expect(f.model.selectedRecoveryEntries.first?.receipt?.status == "unknown")
        #expect(f.model.recoveryPresentation.unknown && !f.model.recoveryPresentation.canContinue)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.tools.executions == 1, "An uncertain execution must not run again")
    }

    @Test func `preparation classification keeps refusals distinct from invalid input`() {
        let errors: [(Error, AskExecutionStatus)] = [
            (AskObservationError.invalid, .invalid), (AskProjectError.denied, .denied),
            (AskArtifactError.denied, .denied), (AskProjectRuntimeError.disabled, .denied),
            (AskProjectRuntimeError.denied, .denied)
        ]
        for (error, status) in errors {
            let failure = AskToolPreparationFailure(error)
            #expect(failure.status == status && failure.outcome.eventDispatched == false)
            #expect(AskToolPreparationFailure(failure).message == failure.localizedDescription)
        }
    }

    @Test func `ending an interrupted call preserves history and draft`() async throws {
        let f = try Fixture()
        defer { f.close() }
        await f.open(.init(id: "call", function: .init(name: "computer", arguments: #"{"action":"click"}"#)))
        f.model.draft.text = "Keep this unfinished follow-up"
        let messages = f.model.selected?.messages
        #expect(f.model.recoveryPresentation.canEnd)
        await f.model.endRecoveryRun()
        #expect(f.model.selected?.run?.status == "cancelled")
        #expect(f.model.selected?.messages == messages)
        #expect(f.model.draft.text == "Keep this unfinished follow-up")
        #expect(!f.model.recoveryPresentation.canEnd && !f.model.recoveryPresentation.canContinue)
        #expect(await f.base.api.results.isEmpty && f.desktop.events.isEmpty)
    }

    @Test func `classified failure advances the real local engine`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AskLocalEngine(directory: root)
        var value = try await engine.send(conversationId: UUID().uuidString,
                                          request: .init(id: UUID().uuidString, deviceId: "device", text: "Inspect",
                                                         tools: AskLocalTools.builtins, modelRef: "custom:fixture"),
                                          token: "")
        let run = try #require(value.run), inference = try #require(run.inference)
        value = try await engine.inferenceResult(conversationId: value.id,
                                                 request: .init(
                                                     runId: run.id,
                                                     deviceId: "device",
                                                     inferenceId: inference.id,
                                                     content: "",
                                                     toolCalls: [.init(
                                                         id: "call",
                                                         function: .init(
                                                             name: "computer",
                                                             arguments: #"{"action":"click"}"#
                                                         )
                                                     )]
                                                 ), token: "")
        #expect(value.run?.status == "waiting_tool")
        let refusal = AskToolPreparationFailure(AskObservationError.disabled)
        let receipt = AskToolResultRequest(runId: run.id, deviceId: "device", toolCallId: "call",
                                           content: refusal.message, isError: true, harness: .init(
                                               version: 1,
                                               outcome: refusal.outcome
                                           ))
        value = try await engine.result(conversationId: value.id, request: receipt, token: "")
        #expect(value.run?.status == "waiting_inference" && value.run?.pending.isEmpty == true)
        #expect(value.run?.needsRecoveryInspection == false)
        #expect(value.messages.last?.harness?.outcome?.status == "denied")
        let duplicate = try await engine.result(conversationId: value.id, request: receipt, token: "")
        #expect(duplicate.revision == value.revision)
    }
}
