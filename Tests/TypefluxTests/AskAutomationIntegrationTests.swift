import AppKit
import Testing
@testable import Typeflux

@Suite("Production automation routing", .exclusiveUIState)
@MainActor
struct AskAutomationIntegrationTests {
    func tools(owner: @escaping @MainActor () -> String = { "owner" }) -> (AskLocalTools, ObservationScriptRunner) {
        let runner = ObservationScriptRunner()
        let registry = MCPRegistry(settingsStore: .init(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        let tools = AskLocalTools(registry: registry, runner: runner, owner: owner)
        tools.runningBundleIdentifiers = { ["com.apple.Safari"] }
        tools.browserExecutor.processInstance = { _ in "42:1" }
        return (tools, runner)
    }

    func call(_ tool: String, _ args: [String: Any]) throws -> AskToolCall {
        .init(id: UUID().uuidString, function: .init(name: tool, arguments: String(
            decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self
        )))
    }

    func observe(_ tools: AskLocalTools, _ tool: String, approved: Bool = false) async throws -> AskLocalToolOutput {
        let call = try call(tool, ["action": tool == "browser" ? "snapshot" : "inspect"])
        if approved {
            let binding = try await tools.approvalBinding(for: call, conversationId: "c")
            #expect(!binding.allowsReuse)
            return try await tools.executeApproved(call, conversationId: "c", binding: binding, authorize: {})
        }
        return try await tools.execute(call, conversationId: "c")
    }

    @Test(arguments: ["browser", "computer"])
    func writesAreClosedAtBothProductionEntrypoints(_ tool: String) async throws {
        let (tools, runner) = tools()
        let desktop = AskComputerExecutorTests.Desktop()
        tools.computerEnvironment = { _ in desktop.environment }
        let observation = try await observe(tools, tool, approved: true)
        let id = try #require(observation.observation?.id)
        let write = try call(tool, ["action": "click", "observation_id": id, "ref": id + ":1", "x": 0.2, "y": 0.2])
        let scriptCount = runner.scripts.count
        await #expect(throws: AskObservationError.disabled) { try await tools.execute(write, conversationId: "c") }
        await #expect(throws: AskObservationError.disabled) { try await tools.approvalBinding(for: write, conversationId: "c") }
        #expect(desktop.events.isEmpty); #expect(runner.scripts.count == scriptCount)
        let definitions = await tools.definitions(conversationId: "c")
        let definition = try #require(definitions.first { $0.name == tool })
        let schema = try JSONSerialization.jsonObject(with: definition.parameters.data) as! [String: Any]
        let properties = schema["properties"] as! [String: [String: Any]]
        #expect(properties["observation_id"]?["type"] as? String == "string")
        if tool == "browser" { #expect(properties["ref"]?["type"] as? String == "string") }
        #expect(definition.description.contains("Only observation is available"))
        #expect(properties["action"]?["enum"] as? [String] ==
            (tool == "browser" ? ["read", "snapshot"] : ["screenshot", "inspect", "wait"]))
    }

    @Test(arguments: [false, true])
    func browserWritePinsObservedBrowserAndRetainsTypedFailure(_ approved: Bool) async throws {
        let (tools, runner) = tools()
        tools.browserExecutor.writesEnabled = true // Only this injected fixture enables writes.
        let output = try await observe(tools, "browser", approved: approved)
        let id = try #require(output.observation?.id)
        // A later fallback candidate must not redirect a write to Chrome.
        tools.runningBundleIdentifiers = { ["com.google.Chrome"] }
        let write = try call("browser", ["action": "click", "ref": id + ":9", "observation_id": id])
        runner.result = #"{"status":"invalid","message":"Element not found","event_dispatched":false,"effect_verified":false}"#
        let result: AskLocalToolOutput
        if approved {
            let binding = try await tools.approvalBinding(for: write, conversationId: "c")
            #expect(binding.target.id == "com.apple.Safari"); #expect(!binding.allowsReuse)
            result = try await tools.executeApproved(write, conversationId: "c", binding: binding, authorize: {})
        } else { result = try await tools.execute(write, conversationId: "c") }
        #expect(result.isError); #expect(result.outcome?.status == "invalid")
        #expect(result.outcome?.eventDispatched == false); #expect(result.content.contains("Element not found"))
        #expect(runner.scripts.last?.contains("com.apple.Safari") == true)
        await #expect(throws: AskObservationError.needsObservation) { try await tools.execute(write, conversationId: "c") }
    }

    @Test(arguments: ["owner", "conversation", "rebind", "forged", "legacy ref", "process exit"])
    func untrustedOrStaleBrowserEvidenceCannotDispatch(_ change: String) async throws {
        var owner = "owner"
        let (tools, runner) = tools(owner: { owner })
        tools.browserExecutor.writesEnabled = true
        let output = try await observe(tools, "browser")
        let id = try #require(output.observation?.id)
        var args: [String: Any] = ["action": "click", "ref": id + ":1", "observation_id": id,
                                   "owner": "owner", "conversation": "c", "browser_id": "com.apple.Safari"]
        if change == "owner" { owner = "other" }
        if change == "rebind" { tools.bindConversation("c") }
        if change == "forged" { args["observation_id"] = "forged" }
        if change == "legacy ref" { args["ref"] = 1 }
        if change == "process exit" { tools.browserExecutor.processInstance = { _ in nil } }
        let write = try call("browser", args)
        await #expect(throws: (any Error).self) {
            try await tools.execute(write, conversationId: change == "conversation" ? "other" : "c")
        }
        #expect(!runner.scripts.contains { $0.contains("return state.run") })
    }

    @Test(arguments: ["owner", "rebind", "revoke"])
    func browserPreparationRechecksAuthorizationAfterSuspension(_ change: String) async throws {
        var owner = "owner", revoked = false
        let (tools, runner) = tools(owner: { owner })
        tools.browserExecutor.writesEnabled = true
        let observed = try await observe(tools, "browser")
        let write = try call("browser", ["action": "back", "observation_id": try #require(observed.observation?.id)])
        let binding = try await tools.approvalBinding(for: write, conversationId: "c")
        var reads = 0
        runner.onTarget = {
            reads += 1
            if reads == 2 { // After executeApproved's initial binding check, in executor preparation.
                if change == "owner" { owner = "other" }
                if change == "rebind" { tools.bindConversation("c") }
                revoked = true
            }
        }
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(write, conversationId: "c", binding: binding) {
                if revoked { throw AskObservationError.invalid }
            }
        }
        #expect(!runner.scripts.contains { $0.contains("return state.run") })
    }

    @Test func ownerChangeDuringCaptureDoesNotCreateAnObservation() async throws {
        var owner = "owner"
        let (tools, runner) = tools(owner: { owner })
        runner.onCapture = { owner = "other" }
        await #expect(throws: AskObservationError.needsObservation) { try await observe(tools, "browser") }
        owner = "owner"; runner.onCapture = {}
        tools.browserExecutor.writesEnabled = true
        let write = try call("browser", ["action": "back", "observation_id": "forged"])
        await #expect(throws: AskObservationError.needsObservation) { try await tools.execute(write, conversationId: "c") }
    }

    @Test(arguments: [false, true])
    func computerRoutesWritesThroughObservationAndReleasesCancelledDrag(_ approved: Bool) async throws {
        let (tools, _) = tools()
        let desktop = AskComputerExecutorTests.Desktop()
        tools.computerEnvironment = { _ in desktop.environment }
        tools.computerExecutor.writesEnabled = true
        let observed = try await observe(tools, "computer", approved: approved)
        let write = try call("computer", ["action": "drag", "observation_id": try #require(observed.observation?.id),
                                         "x": 0.2, "y": 0.2, "to_x": 0.6, "to_y": 0.6])
        desktop.onPause = { if $0 == .milliseconds(15) { throw CancellationError() } }
        let result: AskLocalToolOutput
        if approved {
            let binding = try await tools.approvalBinding(for: write, conversationId: "c")
            result = try await tools.executeApproved(write, conversationId: "c", binding: binding, authorize: {})
        } else { result = try await tools.execute(write, conversationId: "c") }
        #expect(result.isError); #expect(result.outcome?.status == "unknown")
        #expect(result.outcome?.eventDispatched == true); #expect(result.outcome?.effectVerified == false)
        #expect(desktop.events.map(\.type) == [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        #expect(desktop.events.last?.location == desktop.events.dropLast().last?.location)
        await #expect(throws: AskObservationError.needsObservation) { try await tools.execute(write, conversationId: "c") }
    }

    @Test(arguments: ["window", "display", "revoke", "scroll coordinates"])
    func computerRejectsChangedApprovalAndLateRevocation(_ change: String) async throws {
        let (tools, _) = tools()
        let desktop = AskComputerExecutorTests.Desktop()
        tools.computerEnvironment = { _ in desktop.environment }; tools.computerExecutor.writesEnabled = true
        let observed = try await observe(tools, "computer")
        var args: [String: Any] = ["action": "scroll", "amount": 2, "observation_id": try #require(observed.observation?.id)]
        if change != "scroll coordinates" { args["x"] = 0.2; args["y"] = 0.2 }
        let write = try call("computer", args)
        if change == "scroll coordinates" {
            await #expect(throws: AskObservationError.invalid) { try await tools.approvalBinding(for: write, conversationId: "c") }
        } else {
            let binding = try await tools.approvalBinding(for: write, conversationId: "c")
            var revoked = false
            if change == "revoke" { desktop.onPause = { _ in revoked = true } }
            else { desktop.current.reference.target.version = change }
            await #expect(throws: (any Error).self) {
                try await tools.executeApproved(write, conversationId: "c", binding: binding) {
                    if revoked { throw AskObservationError.invalid }
                }
            }
        }
        #expect(desktop.events.isEmpty)
    }

    @Test(arguments: ["success", "display mismatch", "display changed", "revoked", "denied"])
    func screenshotWithoutAXStaysReadOnlyAndChecksExactDisplay(_ scenario: String) async throws {
        let (tools, _) = tools()
        let desktop = AskComputerExecutorTests.Desktop()
        tools.computerEnvironment = { _ in desktop.environment }
        let old = try await observe(tools, "computer")
        desktop.unavailable = true
        var display: UInt32 = 7, revoked = false
        tools.screenObservation.target = { .init(display: display, binding: .init(kind: "desktop_window", id: "display:\(display)", version: "topology")) }
        tools.screenObservation.capture = { requested in
            #expect(requested == 7)
            if scenario == "denied" { throw AskLocalError.message("Screen capture denied") }
            if scenario == "display changed" { display = 8 }
            revoked = scenario == "revoked"
            return .init(dataURL: "image", displayId: scenario == "display mismatch" ? 8 : 7, width: 100, height: 100)
        }
        let screenshot = try call("computer", ["action": "screenshot"])
        let binding = try await tools.approvalBinding(for: screenshot, conversationId: "c")
        #expect(!binding.allowsReuse)
        func capture() async throws -> AskLocalToolOutput {
            try await tools.executeApproved(screenshot, conversationId: "c", binding: binding) {
                if revoked { throw AskObservationError.invalid }
            }
        }
        if scenario == "success" {
            let output = try await capture()
            #expect(output.image == "image"); #expect(output.observation == nil)
            #expect(output.outcome?.eventDispatched == false); #expect(output.content.contains("Read-only"))
            let raw = try await tools.execute(screenshot, conversationId: "c")
            #expect(raw.observation == nil); #expect(raw.image == "image")
        } else { await #expect(throws: (any Error).self) { try await capture() } }
        desktop.unavailable = false; tools.computerExecutor.writesEnabled = true
        let stale = try call("computer", ["action": "click", "x": 0.2, "y": 0.2, "observation_id": try #require(old.observation?.id)])
        await #expect(throws: AskObservationError.needsObservation) { try await tools.execute(stale, conversationId: "c") }
        #expect(desktop.events.isEmpty)
    }

    @Test func observationsAndUnknownOutcomesSurviveJournalAndLegacyProjection() async throws {
        let (tools, runner) = tools()
        let output = try await observe(tools, "browser")
        var receipt = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "call", content: "", isError: false)
        receipt.record(output)
        #expect(receipt.harness?.observation == output.observation)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        try await cache.saveToolResult(receipt, owner: "owner")
        let reopened = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        let stored = try await reopened.toolResult(id: "run/call", owner: "owner")
        let savedObservation = try #require(stored?.harness?.observation)
        #expect(savedObservation.id == output.observation?.id)
        #expect(savedObservation.target == output.observation?.target)
        #expect(savedObservation.processInstanceId == output.observation?.processInstanceId)
        #expect(abs(savedObservation.capturedAt.timeIntervalSince(try #require(output.observation?.capturedAt))) < 1)
        #expect(stored?.legacyProjection().content.contains("observation") == true)
        tools.browserExecutor.writesEnabled = true; runner.failAction = true
        let write = try call("browser", ["action": "back", "observation_id": try #require(output.observation?.id)])
        let unknown = try await tools.execute(write, conversationId: "c")
        receipt.record(unknown)
        #expect(receipt.harness?.observation == nil)
        #expect(receipt.harness?.outcome?.status == "unknown")
        #expect(receipt.message(step: 1, now: Date()).isError == true)
        #expect(receipt.legacyProjection().content.contains("do not automatically replay"))
        let restoredTools = self.tools().0
        restoredTools.browserExecutor.writesEnabled = true
        await #expect(throws: AskObservationError.needsObservation) { try await restoredTools.execute(write, conversationId: "c") }
    }
}
