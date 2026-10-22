import Foundation
import Testing
@testable import Typeflux

@Suite("Recovery execution safety", .serialized, .exclusiveUIState)
@MainActor
struct AskRecoverySafetyTests {
    @MainActor struct Intent {
        let fixture: AskTestFixture
        let value: AskConversation
        let identity: AskExecutionIdentity
        let request: AskToolResultRequest
        let grant: String

        init(recovery: Bool = false, tool: String = "web_search") async throws {
            fixture = try AskTestFixture()
            var value = AskRecoveryFixture.conversation()
            value.run?.recoveryCheck = recovery
            value.run?.clientToolApproval = true
            value.run?.pending[0].function.name = tool
            let definition = AskToolDefinition(
                name: tool,
                description: "Cloud tool",
                parameters: JSONValue(data: Data("{}".utf8))
            )
            value.run?.cloudTools = [definition]
            self.value = value
            await fixture.api.seed(value)
            await fixture.model.select(value.id)
            fixture.model.stopSelectionObservation()
            let run = try #require(value.run), call = try #require(run.pending.first)
            identity = .init(owner: "owner", conversation: value, run: run, callId: call.id, kind: "tool")
            let binding = try await fixture.model.preparedToolBinding(
                call,
                conversationId: value.id,
                cloudDefinition: definition
            )
            let approval = AskToolPolicy.request(call: call, owner: "owner", conversation: value.id, run: run.id,
                                                 step: String(run.steps), binding: binding, risk: .read)
            grant = try #require(fixture.model.approvalStore.issue(approval))
            #expect(fixture.model.approvalStore.consume(grant, for: approval))
            fixture.model.cloudApprovals[identity.key] = (grant, approval)
            request = .init(approveExecution: true, runId: run.id, deviceId: "device", toolCallId: call.id,
                            content: "Tool execution authorized.", isError: false)
            let audit = AskExecutionAudit(identity: identity, toolVersion: binding.toolVersion,
                                          toolName: tool, argumentsHash: approval.context.argumentsHash,
                                          approvalId: grant)
            #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
            try await fixture.cache.saveReceipt(.tool(request), identity: identity, owner: "owner")
        }

        func acknowledged() async throws -> Bool {
            try #require(await fixture.cache.execution(id: identity.key, owner: "owner")).acknowledged
        }
    }

    @Test(arguments: ["expired", "missing", "revoked", "restart"])
    func `cached approval needs live grant`(_ scenario: String) async throws {
        let intent = try await Intent(), fixture = intent.fixture
        defer { fixture.model.resetSession() }
        var model = fixture.model
        switch scenario {
        case "expired": model.approvalStore.now = { .now.addingTimeInterval(600) }
        case "missing": model.cloudApprovals = [:]
        case "revoked": model.approvalStore.revoke(conversation: intent.value.id)
        default:
            fixture.model.resetSession()
            model = AskConversationModel(
                api: fixture.api,
                cache: fixture.cache,
                tools: fixture.tools,
                capture: fixture.capture,
                deviceId: "device",
                modelLibrary: fixture.model.modelLibrary,
                session: { ("owner", "token") }
            )
            model.lastConversationKind = .work // Predates conversation kinds: keep tool flows.
            model.automaticRecoveryEnabled = false
            await model.select(intent.value.id)
        }
        defer { model.resetSession() }
        await model.retransmitSavedReceipts()
        #expect(await fixture.api.results.isEmpty)
        #expect(try await !intent.acknowledged())
        #expect(model.error != nil && model.pendingApprovals.isEmpty && fixture.tools.executions == 0)
        model.automaticRecoveryEnabled = true
        await model.recoverWithoutUser()
        await model.recoverWithoutUser()
        #expect(await fixture.api.sends.isEmpty)
    }

    @Test func `same session grant and already acknowledged intent`() async throws {
        for scenario in ["pending", "acknowledged", "replaced"] {
            let acknowledged = scenario != "pending"
            let intent = try await Intent(), fixture = intent.fixture
            defer { fixture.model.resetSession() }
            if acknowledged {
                var value = intent.value
                value.revision += 1
                value.run?.pending = []; value.run?.status = "completed"
                if scenario == "replaced" {
                    value.run?.id = "replacement"
                }
                value.messages.append(.init(id: "receipt", role: "tool", text: "Already received",
                                            toolCallId: intent.identity.callId, createdAt: Date(),
                                            runId: intent.identity.runId))
                await fixture.api.seed(value)
                fixture.model.approvalStore.reset()
            }
            await fixture.model.retransmitSavedReceipts()
            #expect(await fixture.api.results.count == (acknowledged ? 0 : 1))
            #expect(try await intent.acknowledged())
            #expect(fixture.tools.executions == 0)
        }
    }

    @Test(arguments: ["account", "generation", "operation", "run", "device", "call", "arguments", "definition"])
    func `refresh cannot authorize replaced work`(_ change: String) async throws {
        let intent = try await Intent(), fixture = intent.fixture
        defer { fixture.model.resetSession() }
        let route = try #require(fixture.model.credentials(for: intent.value.id))
        await fixture.api.hold(intent.value.id)
        let send = Task { try await fixture.model.deliverToolResult(
            intent.request,
            identity: intent.identity,
            current: route
        ) }
        for _ in 0 ..< 1000 {
            if await fixture.api.waiting[intent.value.id]?.isEmpty == false {
                break
            }
            await Task.yield()
        }
        #expect(await fixture.api.waiting[intent.value.id]?.isEmpty == false)
        let changed = replacement(intent.value, change: change, fixture: fixture)
        await fixture.api.seed(changed)
        await fixture.api.release(intent.value.id)
        do { _ = try await send.value; Issue.record("Obsolete approval sent") } catch {}
        #expect(await fixture.api.results.isEmpty)
        #expect(try await !intent.acknowledged())
        #expect(fixture.tools.executions == 0)
    }

    private func replacement(_ value: AskConversation, change: String, fixture: AskTestFixture) -> AskConversation {
        var changed = value
        changed.revision += 1
        switch change {
        case "account": fixture.sessionState.owner = "different"
        case "generation": fixture.model.recoveryGeneration = UUID()
        case "operation": fixture.model.operationGenerations[changed.id] = UUID()
        case "run": changed.run?.id = "replacement"
        case "device": changed.run?.deviceId = "replacement"
        case "call": changed.run?.pending[0].id = "replacement"
        case "arguments": changed.run?.pending[0].function.arguments = #"{"query":"changed"}"#
        default: changed.run?.cloudTools?[0].description = "Changed definition"
        }
        return changed
    }

    @Test(arguments: [false, true])
    func `denial and completed write receipts do not need another grant`(_ denial: Bool) async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var value = AskRecoveryFixture.conversation()
        value.run?.recoveryCheck = true
        value.run?.status = "cancelled"
        value.run?.pending[0].function.arguments = #"{"action":"write"}"#
        let audit = AskRecoveryFixture.audit(value)
        var receipt = AskToolResultRequest(runId: audit.identity.runId, deviceId: "device", toolCallId: "call",
                                           content: "Completed receipt", isError: denial)
        if denial {
            receipt.approveExecution = false
        }
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        try await fixture.cache.saveReceipt(.tool(receipt), identity: audit.identity, owner: "owner")
        await fixture.api.seed(value)
        await fixture.model.select(value.id)
        await fixture.model.retransmitSavedReceipts()
        #expect(await fixture.api.results == [receipt])
        #expect(try await fixture.cache.execution(id: audit.identity.key, owner: "owner")?.acknowledged == true)
        #expect(fixture.tools.executions == 0)
    }

    @Test func `late inference receipt settles only its original identity after replacement`() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var original = AskRecoveryFixture.conversation(model: true)
        original.messages[0].createdAt = original.updatedAt
        let audit = AskRecoveryFixture.audit(original, model: true)
        let receipt = AskRecoveryFixture.receipt(original, model: true)
        #expect(try await fixture.cache.claimExecution(audit, owner: "owner"))
        try await fixture.cache.saveReceipt(receipt, identity: audit.identity, owner: "owner")
        var replacement = original
        replacement.revision += 1
        replacement.run?.id = "replacement"
        replacement.run?.status = "completed"
        replacement.run?.inference = nil
        await fixture.api.seed(replacement)
        await fixture.model.select(replacement.id)
        await fixture.model.retransmitSavedReceipts()
        await fixture.model.retransmitSavedReceipts()
        let results = await fixture.api.inferenceResults
        #expect(results.count == 1 && results.first?.runId == audit.identity.runId)
        #expect(fixture.model.selected?.run?.id == replacement.run?.id)
        #expect(fixture.model.selected?.messages == replacement.messages)
        #expect(try await fixture.cache.execution(id: audit.identity.key, owner: "owner")?.acknowledged == true)
        #expect(fixture.tools.executions == 0 && fixture.model.pendingApprovals.isEmpty)
    }

    @Test func `cached cloud write cannot bypass recovery fence`() async throws {
        let intent = try await Intent(recovery: true, tool: "run_command"), fixture = intent.fixture
        defer { fixture.model.resetSession() }
        await fixture.model.retransmitSavedReceipts()
        #expect(await fixture.api.results.isEmpty)
        #expect(try await !intent.acknowledged())
        #expect(fixture.tools.executions == 0)
    }

    @Test func `intrinsic observation matrix and offered actions`() throws {
        let expected: [String: Set<String>] = [
            "computer": ["screenshot", "inspect", "wait"], "browser": ["read", "snapshot"],
            "web_browser": ["read", "snapshot", "screenshot", "tabs", "wait"], "files": ["list", "read", "search"],
            "project_files": ["list", "read", "review"], "project_terminal": ["status", "output"]
        ]
        for (tool, actions) in expected {
            for action in actions {
                #expect(AskRecoveryObservation.permits(.init(
                    id: "c",
                    function: .init(name: tool, arguments: "{\"action\":\"\(action)\"}")
                )))
            }
        }
        for tool in Array(expected.keys) + ["mcp_read", "memory", "unknown"] {
            for raw in ["{", "[]", "{}", #"{"action":1}"#, #"{"action":"write"}"#, #"{"action":"info"}"#] {
                #expect(!AskRecoveryObservation.permits(.init(id: "c", function: .init(name: tool, arguments: raw))))
            }
        }
        for tool in ["web_search", "web_fetch"] {
            #expect(AskRecoveryObservation.permits(.init(id: "c", function: .init(name: tool, arguments: "{}"))))
        }
        let definitions = try expected.map { tool, actions in
            let schema: [String: Any] = ["properties": ["action": ["enum": Array(actions).sorted() + ["write"]]]]
            return try AskToolDefinition(
                name: tool,
                description: "Test",
                parameters: JSONValue(data: JSONSerialization.data(withJSONObject: schema))
            )
        }
        let offered = AskConversationModel.recoveryObservationTools(definitions)
        #expect(offered.count == expected.count)
        for definition in offered {
            let schema = try #require(JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            let actions = try #require(properties["action"]?["enum"] as? [String])
            #expect(Set(actions) == expected[definition.name])
        }
        let invalid = [
            AskToolDefinition(name: "files", description: "Bad", parameters: JSONValue(data: Data("{}".utf8))),
            .init(name: "mcp_read", description: "External claim", parameters: JSONValue(data: Data("{}".utf8)))
        ]
        #expect(AskConversationModel.recoveryObservationTools(invalid).isEmpty)
    }

    @Test(arguments: AskPermissionMode.allCases)
    func `permissive presentation cannot authorize recovery writes`(_ mode: AskPermissionMode) async throws {
        for action in ["click", "fill", "open", "new_tab", "select_tab", "close_tab", "handoff", "read"] {
            let fixture = try AskTestFixture()
            defer { fixture.model.resetSession() }
            var value = AskRecoveryFixture.conversation()
            value.run?.recoveryCheck = true
            value.run?.pending[0].function.name = "web_browser"
            value.run?.pending[0].function.arguments = "{\"action\":\"\(action)\"}"
            await fixture.api.seed(value)
            await fixture.model.select(value.id)
            fixture.tools.riskOverride = .read // A trusted site's presentation cannot authorize effects.
            fixture.model.setPermissionMode(mode, launcher: false)
            fixture.model.resume()
            if action == "read", mode == .strict {
                try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
                fixture.model.approve(conversationId: value.id, allowed: true)
            }
            try await fixture.wait { fixture.model.busyIds.isEmpty }
            #expect(fixture.tools.executions == (action == "read" ? 1 : 0))
            #expect(await fixture.api.results.count == 1)
            #expect(await fixture.api.results.allSatisfy { $0.approveExecution != true })
            #expect(fixture.model.pendingApprovals.isEmpty)
        }
    }
}
