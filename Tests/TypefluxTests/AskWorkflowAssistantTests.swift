import AppKit
import Foundation
import Testing
@testable import Typeflux

/// A scripted Ask service: each send or tool result moves to the next step,
/// either a tool call the assistant must run or a final reply.
actor AskWorkflowScriptedAPI: AskAPI {
    enum Step { case tool(String, [String: Any]), reply(String), running, fail(String), inference(String) }

    private var steps: [Step]
    private var holdRunning: Bool
    private(set) var sends: [AskSendRequest] = []
    private(set) var results: [AskToolResultRequest] = []
    private(set) var cancels = 0
    private var values: [String: AskConversation] = [:]

    init(_ steps: [Step], holdRunning: Bool = false) {
        self.steps = steps
        self.holdRunning = holdRunning
    }

    func releaseRunning() {
        holdRunning = false
    }

    func enqueue(_ more: [Step]) {
        steps += more
    }

    private func advance(_ id: String, deviceId: String) -> AskConversation {
        var value = values[id] ?? AskConversation(id: id, title: "t", revision: 0, updatedAt: Date(), messages: [])
        let run = value.run ?? AskRun(id: "run-1", deviceId: deviceId, status: "running", steps: 0, updatedAt: Date(),
                                      tools: [], pending: [])
        value.run = run
        if steps.isEmpty {
            value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: "Done.", createdAt: Date()))
            value.run?.status = "completed"
            value.run?.pending = []
        } else {
            switch steps.removeFirst() {
            case let .tool(name, arguments):
                let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data("{}".utf8)
                let call = AskToolCall(id: UUID().uuidString, type: "function",
                                       function: .init(name: name, arguments: String(decoding: data, as: UTF8.self)))
                value.messages.append(.init(
                    id: UUID().uuidString,
                    role: "assistant",
                    text: "",
                    toolCalls: [call],
                    createdAt: Date()
                ))
                value.run?.status = "waiting_tool"
                value.run?.pending = [call]
            case let .reply(text):
                value.messages.append(.init(id: UUID().uuidString, role: "assistant", text: text, createdAt: Date()))
                value.run?.status = "completed"
                value.run?.pending = []
            case .running:
                value.run?.status = "running"
                value.run?.preview = "Thinking"
                value.run?.pending = []
            case let .fail(message):
                value.run?.status = "failed"
                value.run?.error = message
                value.run?.pending = []
            case let .inference(model):
                value.run?.status = "waiting_inference"
                value.run?.modelRef = model
                value.run?.inference = AskInference(id: "inference-1", payload: "{}", summaryThrough: nil)
                value.run?.pending = []
            }
        }
        value.revision += 1
        values[id] = value
        return value
    }

    func send(conversationId: String, request: AskSendRequest, token _: String) async throws -> AskConversation {
        sends.append(request)
        var value = values[conversationId] ?? AskConversation(id: conversationId, title: request.text, revision: 0,
                                                              updatedAt: Date(), messages: [])
        value.messages.append(.init(id: request.id, role: "user", text: request.text, createdAt: Date()))
        value.run = nil
        values[conversationId] = value
        return advance(conversationId, deviceId: request.deviceId)
    }

    func result(conversationId: String, request: AskToolResultRequest,
                token _: String) async throws -> AskConversation {
        results.append(request)
        values[conversationId]?.messages.append(.init(id: UUID().uuidString, role: "tool", text: request.content,
                                                      toolCallId: request.toolCallId, isError: request.isError,
                                                      createdAt: Date()))
        return advance(conversationId, deviceId: request.deviceId)
    }

    func conversation(id: String, token _: String) async throws -> AskConversation {
        guard let value = values[id] else { throw AskLocalError.message("missing") }
        // A running step finishes by the next read.
        if value.run?.status == "running", !holdRunning {
            return advance(id, deviceId: value.run?.deviceId ?? "")
        }
        return value
    }

    func cancel(conversationId: String, runId _: String, token: String) async throws -> AskConversation {
        cancels += 1
        return try await conversation(id: conversationId, token: token)
    }

    func observe(
        id _: String,
        token _: String,
        onValue _: @Sendable (AskConversation) async throws -> Void
    ) async throws {}
    func models(token _: String) async throws -> [AskCloudModel] {
        []
    }

    func models(token _: String, scenario _: String) async throws -> [AskCloudModel] {
        []
    }

    func inferenceResult(conversationId: String, request _: AskInferenceResult,
                         token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }

    func list(token _: String, offset _: Int) async throws -> [AskConversationSummary] {
        []
    }

    func retry(conversationId: String, runId _: String, deviceId _: String, modelRef _: String?,
               token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }

    func regenerate(conversationId: String, request _: AskRegenerateRequest,
                    token: String) async throws -> AskConversation {
        try await conversation(id: conversationId, token: token)
    }

    func delete(conversationId _: String, token _: String) async throws {}
    func purgeMemory(token _: String) async throws {}
    func purgeMemory(owner _: String, token _: String) async throws {}
}

@MainActor
private func waitFor(_ what: String = "condition", _ condition: () -> Bool) async {
    for _ in 0 ..< 1500 {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(4))
    }
    Issue.record("Timed out waiting for \(what)")
}

@MainActor
private func makeAssistant(_ api: any AskAPI, token: String = "token",
                           defaults: UserDefaults? = nil) -> AskWorkflowAssistant {
    let defaults = defaults ?? UserDefaults(suiteName: "wf-assistant-\(UUID().uuidString)")!
    let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
    return AskWorkflowAssistant(dependencies: .init(api: api, session: { ("owner", token) }, deviceId: "device",
                                                    modelLibrary: library, defaults: defaults))
}

private let echoManifest: [String: Any] = [
    "schema": 1, "id": "local.echo", "name": "Echo", "keywords": [["keyword": "ec"]],
    "command": ["runtime": "zsh", "script": "main.sh"], "output": "text"
]

/// A host that records what the tools ask of it.
@MainActor
private final class RecordingHost: AskWorkflowAuthoringHost {
    var draft: AskWorkflowDraft
    var submitted: [AskWorkflowProposal] = []
    var tests: [[AskWorkflowTestInput]] = []
    var allowTests = true
    var authoringTestFailure: AskWorkflowAuthoringTestFailure? { allowTests ? nil : .declined }
    var taken: Set<String> = ["tr"]

    init(draft: AskWorkflowDraft) {
        self.draft = draft
    }

    var authoringDraft: AskWorkflowDraft {
        submitted.last.map { $0.applied(to: draft) } ?? draft
    }

    var authoringWorkflowID: String? {
        "local.echo"
    }

    var lastTestResult: AskWorkflowTestResult? {
        AskWorkflowTestResult(input: .init(query: "q"), exitCode: 1, stdout: "", stderr: "boom", duration: 0.1)
    }

    func keywordProblem(_ keyword: String) -> String? {
        taken.contains(keyword) ? "taken" : nil
    }

    func submit(_ proposal: AskWorkflowProposal) -> AskWorkflowProposal {
        var proposal = proposal
        proposal.risks = AskWorkflowRiskScanner.scan(proposal.files)
        submitted.append(proposal)
        return proposal
    }

    func testLatestProposal(_ inputs: [AskWorkflowTestInput]) async -> [AskWorkflowTestResult]? {
        tests.append(inputs)
        guard allowTests else { return nil }
        return inputs.map { AskWorkflowTestResult(
            input: $0,
            exitCode: 0,
            stdout: String(repeating: "x", count: 5000),
            stderr: "",
            duration: 0.2
        ) }
    }
}

@Suite("Ask workflow author tools")
@MainActor
struct AskWorkflowAuthorToolsTests {
    private let folder = URL(fileURLWithPath: "/tmp/wf-tools")

    private func call(_ name: String, _ arguments: [String: Any]) -> AskToolCall {
        let data = (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data()
        return AskToolCall(
            id: "c",
            type: "function",
            function: .init(name: name, arguments: String(decoding: data, as: UTF8.self))
        )
    }

    private func host() -> RecordingHost {
        RecordingHost(draft: AskWorkflowDraft(folder: folder, manifestText: AskWorkflowDraft.format(echoManifest) ?? "",
                                              files: ["main.sh": "print -r -- \"$1\"\n"]))
    }

    @Test func definitionsAreTheFiveToolsWithObjectSchemas() throws {
        let definitions = AskWorkflowAuthorTools.definitions
        #expect(Set(definitions.map(\.name)) == AskWorkflowAuthorTools.names)
        for definition in definitions {
            let schema = try JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any]
            #expect(schema?["type"] as? String == "object")
            #expect(definition.name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil)
        }
        #expect(AskWorkflowAuthorSkill.instructions.count < 40000)
        #expect(AskWorkflowAuthorSkill.use.name == "typeflux-workflow-author")
    }

    @Test func readShowsTheWorkflowOrOneFile() async throws {
        let tools = AskWorkflowAuthorTools()
        let host = host()
        let overview = await tools.execute(call("workflow_read", [:]), host: host)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(overview.content.utf8)) as? [String: Any])
        #expect(object["manifest"] as? String == host.draft.manifestText)
        #expect((object["lastTest"] as? [String: Any])?["stderr"] as? String == "boom")
        #expect(object["isNew"] as? Bool == false)
        let file = await tools.execute(call("workflow_read", ["path": "main.sh"]), host: host)
        #expect(file.content.contains("print") && !file.isError)
        let missing = await tools.execute(call("workflow_read", ["path": "nope.sh"]), host: host)
        #expect(missing.isError)
    }

    @Test func keywordsAreChecked() async {
        let tools = AskWorkflowAuthorTools()
        let free = await tools.execute(call("workflow_check_keyword", ["keyword": "ok"]), host: host())
        #expect(free.content.contains("\"available\":true"))
        let taken = await tools.execute(call("workflow_check_keyword", ["keyword": "tr"]), host: host())
        #expect(taken.content.contains("\"available\":false") && taken.content.contains("taken"))
    }

    @Test func proposalsAreValidatedBeforeTheHostSeesThem() async {
        let tools = AskWorkflowAuthorTools()
        let host = host()
        let noManifest = await tools.execute(call("workflow_propose", ["summary": "s"]), host: host)
        #expect(noManifest.isError && host.submitted.isEmpty)
        let outside = await tools.execute(call("workflow_propose", ["summary": "s", "manifest": echoManifest,
                                                                    "files": [["path": "../x.sh", "content": "x"]]]),
                                          host: host)
        #expect(outside.isError && host.submitted.isEmpty)
        let badFile = await tools.execute(call("workflow_propose", ["summary": "s", "manifest": echoManifest,
                                                                    "files": [["path": "x.sh"]]]), host: host)
        #expect(badFile.isError)
        var broken = echoManifest
        broken["keywords"] = [["keyword": "tr"]]
        let taken = await tools.execute(call("workflow_propose", ["summary": "s", "manifest": broken]), host: host)
        #expect(taken.isError && taken.content.contains("keywords[0]"))
        var missingScript = echoManifest
        missingScript["command"] = ["runtime": "zsh", "script": "other.sh"]
        let missing = await tools.execute(
            call("workflow_propose", ["summary": "s", "manifest": missingScript]),
            host: host
        )
        #expect(missing.isError && missing.content.contains("command.script"))
        let accepted = await tools.execute(call("workflow_propose", [
            "summary": "Fetch", "manifest": echoManifest,
            "files": [["path": "main.sh", "content": "curl -s https://api.example.com/x\n"]]
        ]), host: host)
        #expect(!accepted.isError && accepted.proposalID == host.submitted.last?.id)
        #expect(host.submitted.last?.manifestText == nil, "the same manifest is no change")
        #expect(accepted.content.contains("api.example.com"))
        #expect(host.submitted.count == 1 && host.submitted[0].summary == "Fetch")
    }

    @Test func sRunThroughTheHostAndAreCut() async throws {
        let tools = AskWorkflowAuthorTools()
        let host = host()
        let empty = await tools.execute(call("workflow_test", ["inputs": []]), host: host)
        #expect(empty.isError && host.tests.isEmpty)
        let inputs = (0 ..< 7).map { ["query": "q\($0)", "selection": "s"] }
        let ran = await tools.execute(call("workflow_test", ["inputs": inputs]), host: host)
        #expect(!ran.isError && host.tests.first?.count == AskWorkflowAuthorTools.maximumInputs)
        #expect(host.tests.first?.first?.selection == "s")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(ran.content.utf8)) as? [String: Any])
        let first = try #require((object["results"] as? [[String: Any]])?.first)
        #expect((first["stdout"] as? String)?.hasPrefix("…") == true)
        #expect(((first["stdout"] as? String)?.utf8.count ?? 0) <= AskWorkflowAuthorTools.outputLimit + 3)
        host.allowTests = false
        let declined = await tools.execute(call("workflow_test", ["inputs": [["query": "x"]]]), host: host)
        #expect(declined.isError && declined.content.contains("did not allow"))
        let unknown = await tools.execute(call("files", [:]), host: host)
        #expect(unknown.isError)
    }

    @Test func environmentListsInterpretersAndLooksUpCommands() async throws {
        let probe = AskWorkflowEnvironmentProbe(searchPath: { "/bin:/usr/bin" }, osVersion: "macOS 99")
        let tools = AskWorkflowAuthorTools(probe: probe)
        let output = await tools.execute(
            call("workflow_environment", ["commands": ["ls", "definitely-not-here-xyz", "bad name;"]]),
            host: host()
        )
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.content.utf8)) as? [String: Any])
        #expect(object["macOS"] as? String == "macOS 99")
        let commands = try #require(object["commands"] as? [String: Any])
        #expect(commands["ls"] as? String == "/bin/ls")
        #expect(commands["definitely-not-here-xyz"] is NSNull)
        #expect(commands["bad name;"] == nil)
        let runtimes = try #require(object["runtimes"] as? [String: Any])
        #expect((runtimes["zsh"] as? String)?.contains("/bin/zsh") == true)
        #expect(runtimes["osascript"] as? String == "/usr/bin/osascript")
    }

    @Test func describeAndTailFormatResults() {
        var result = AskWorkflowTestResult(
            input: .init(query: "q", selection: "s"),
            exitCode: 2,
            stdout: "out",
            stderr: "err",
            duration: 1.234,
            timedOut: true,
            truncated: true,
            failure: "nope"
        )
        let object = AskWorkflowAuthorTools.describe(result)
        #expect(object["seconds"] as? Double == 1.23 && object["timedOut"] as? Bool == true)
        #expect(object["selection"] as? String == "s" && object["notStarted"] as? String == "nope")
        #expect(AskWorkflowAuthorTools.tail("short") == "short")
        result.failure = nil
        #expect(!result.succeeded && !result.summary.isEmpty)
        result.timedOut = false
        #expect(result.summary.contains("2"))
    }
}

@Suite("Ask workflow assistant")
@MainActor
struct AskWorkflowAssistantSessionTests {
    private func host() -> RecordingHost {
        RecordingHost(draft: AskWorkflowDraft(folder: URL(fileURLWithPath: "/tmp/wf-a"),
                                              manifestText: AskWorkflowDraft.format(echoManifest) ?? "",
                                              files: ["main.sh": "x"]))
    }

    @Test func aMessageRunsTheToolsAndShowsTheReply() async throws {
        let api = AskWorkflowScriptedAPI([
            .tool("workflow_read", [:]),
            .tool("workflow_propose", ["summary": "Change", "manifest": echoManifest,
                                       "files": [["path": "main.sh", "content": "print hi\n"]]]),
            .reply("All set.")
        ])
        let assistant = makeAssistant(api)
        let host = host()
        assistant.host = host
        assistant.bind(workflowID: "local.echo")
        assistant.send("Make it say hi")
        await waitFor("reply") { !assistant.isBusy && assistant.items.count >= 4 }
        let sends = await api.sends
        let results = await api.results
        #expect(sends.count == 1 && results.count == 2 && results.allSatisfy { !$0.isError })
        let request = try #require(sends.first)
        #expect(Set(request.tools.map(\.name)) == AskWorkflowAuthorTools.names)
        #expect(request.skills?.first?.name == AskWorkflowAuthorSkill.name)
        #expect(request.modelRef == "cloud:default")
        #expect(assistant.items.first == .user(id: request.id, text: "Make it say hi"))
        #expect(assistant.items.contains {
            if case .proposal = $0 {
                true
            } else {
                false
            }
        })
        #expect(assistant.items.last.map {
            if case .reply(_, "All set.") = $0 {
                true
            } else {
                false
            }
        } == true)
        #expect(!assistant.isLocal && assistant.conversationID != nil && assistant.error == nil)
    }

    @Test func toolsOutsideTheWorkflowSetAreRefused() async {
        let api = AskWorkflowScriptedAPI([.tool("files", ["action": "read"]), .reply("ok")])
        let assistant = makeAssistant(api)
        let host = host()
        assistant.host = host
        assistant.send("read my files")
        await waitFor("refusal") { !assistant.isBusy }
        let results = await api.results
        #expect(results.count == 1 && results[0].isError)
    }

    @Test func theToolLimitStopsALoop() async {
        let api = AskWorkflowScriptedAPI(Array(
            repeating: .tool("workflow_read", [:]),
            count: AskWorkflowAssistant.toolCallLimit + 1
        ))
        let assistant = makeAssistant(api)
        let host = host()
        assistant.host = host
        assistant.send("loop")
        await waitFor("limit") { !assistant.isBusy }
        let results = await api.results
        #expect(results.count == AskWorkflowAssistant.toolCallLimit + 1)
        #expect(results.last?.isError == true && results.dropLast().allSatisfy { !$0.isError })
    }

    @Test func conversationsAreRememberedPerWorkflow() async throws {
        let defaults = try #require(UserDefaults(suiteName: "wf-assistant-\(UUID().uuidString)"))
        let api = AskWorkflowScriptedAPI([.reply("First answer.")])
        let assistant = makeAssistant(api, defaults: defaults)
        assistant.host = host()
        assistant.bind(workflowID: "local.echo")
        assistant.send("hello")
        await waitFor("answer") { !assistant.isBusy }
        let id = assistant.conversationID
        let reopened = makeAssistant(api, defaults: defaults)
        reopened.bind(workflowID: "local.echo")
        #expect(reopened.conversationID == id)
        await waitFor("restore") { reopened.items.count == 2 }
        reopened.bind(workflowID: "local.other")
        #expect(reopened.conversationID == nil && reopened.items.isEmpty)
        assistant.rebind(to: "local.renamed")
        let moved = makeAssistant(api, defaults: defaults)
        moved.bind(workflowID: "local.renamed")
        #expect(moved.conversationID == id)
        AskWorkflowAssistant.forget(workflowID: "local.renamed", defaults: defaults)
        moved.bind(workflowID: "local.renamed")
        #expect(moved.conversationID == nil)
    }

    @Test func signedOutConversationsStayOnThisMacAndNeedAModel() {
        let api = AskWorkflowScriptedAPI([])
        let assistant = makeAssistant(api, token: "")
        #expect(assistant.modelReference(local: false) == "cloud:default")
        assistant.send("   ")
        #expect(assistant.items.isEmpty && assistant.conversationID == nil)
        guard assistant.modelReference(local: true) == nil else { return } // This Mac has a model of its own.
        assistant.send("hi")
        #expect(assistant.isLocal)
        #expect(assistant.error == L("ask.workflow.assistant.noModel"))
        #expect(assistant.items.isEmpty && !assistant.isBusy)
        assistant.appendNotice("note")
        #expect(assistant.items.count == 1)
    }

    @Test func runningRunsArePolledAndFailuresShown() async {
        let api = AskWorkflowScriptedAPI([.running, .reply("Polled.")])
        let assistant = makeAssistant(api)
        assistant.host = host()
        assistant.send("poll")
        await waitFor("poll") { !assistant.isBusy }
        #expect(assistant.items.contains {
            if case .reply(_, "Polled.") = $0 {
                true
            } else {
                false
            }
        })
        await api.enqueue([.fail("Model overloaded")])
        assistant.send("again")
        await waitFor("failure") { !assistant.isBusy }
        #expect(assistant.error == "Model overloaded")
    }

    @Test func aMessageWithNothingToDoEndsWithAReply() async {
        let api = AskWorkflowScriptedAPI([])
        let assistant = makeAssistant(api)
        assistant.host = host()
        assistant.send("hi")
        await waitFor("done") { !assistant.isBusy }
        #expect(assistant.items.contains {
            if case .reply(_, "Done.") = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func stepsForAModelThatIsNotThereFail() async {
        let api = AskWorkflowScriptedAPI([.inference("custom:missing")])
        let assistant = makeAssistant(api)
        assistant.host = host()
        assistant.send("hi")
        await waitFor("failure") { !assistant.isBusy }
        #expect(assistant.error == L("ask.models.unavailable"))
    }

    @Test func cancelledToolCannotAppendToTheNextConversation() async {
        let api = AskWorkflowScriptedAPI([
            .tool("workflow_test", ["inputs": [["query": "old"]]]), .reply("new reply")
        ])
        let assistant = makeAssistant(api)
        let host = SlowHost(draft: AskWorkflowDraft(folder: URL(fileURLWithPath: "/tmp"),
            manifestText: AskWorkflowDraft.format(echoManifest) ?? "", files: ["main.sh": "print test"]))
        assistant.host = host
        assistant.send("old")
        await waitFor { host.started }
        assistant.bind(workflowID: nil)
        assistant.send("new")
        await waitFor { !assistant.isBusy }
        let items = assistant.items
        host.release()
        await waitFor { host.finished }
        #expect(assistant.items == items)
        #expect(await api.results.isEmpty)
        #expect(assistant.error == nil && assistant.preview.isEmpty)
    }

    @Test func stopCancelsTheRun() async {
        let api = AskWorkflowScriptedAPI([.tool("workflow_test", ["inputs": [["query": "x"]]])])
        let assistant = makeAssistant(api)
        let host = SlowHost(draft: AskWorkflowDraft(
            folder: URL(fileURLWithPath: "/tmp"),
            manifestText: AskWorkflowDraft.format(echoManifest) ?? "",
            files: ["main.sh": "print test"]
        ))
        assistant.host = host
        assistant.send("go")
        await waitFor("test call") { host.started }
        assistant.stop()
        #expect(!assistant.isBusy)
        var cancels = 0
        for _ in 0 ..< 200 where cancels == 0 {
            cancels = await api.cancels
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(cancels == 1)
        host.release()
    }
}

/// Holds a value set from a task.
@MainActor
private final class Box<Value> {
    var value: Value?
}

/// A host whose test run waits until released.
@MainActor
private final class SlowHost: AskWorkflowAuthoringHost {
    var draft: AskWorkflowDraft
    var started = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(draft: AskWorkflowDraft) {
        self.draft = draft
    }

    var authoringDraft: AskWorkflowDraft {
        draft
    }

    var authoringWorkflowID: String? {
        nil
    }

    var lastTestResult: AskWorkflowTestResult? {
        nil
    }

    func keywordProblem(_: String) -> String? {
        nil
    }

    func submit(_ proposal: AskWorkflowProposal) -> AskWorkflowProposal {
        proposal
    }

    func testLatestProposal(_: [AskWorkflowTestInput]) async -> [AskWorkflowTestResult]? {
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
        return []
    }

    func release() {
        continuation?.resume(); continuation = nil
    }
}

@Suite("Ask workflow tester")
@MainActor
struct AskWorkflowTesterTests {
    @Test func aTestRunIsTheLaunchersRun() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.t", manifest: AskWorkflowFixture.inline(
            "local.t", keyword: "tt",
            script: #"print -r -- "q=$1 s=${TYPEFLUX_SELECTION:-none} o=$TYPEFLUX_OPTION_TO"; read line; print -r -- "$line""#,
            extra: ["keywords": [["keyword": "tt", "options": ["to": "cny"]]], "input": ["selection": "always"]]
        ))
        fixture.store.reload()
        let workflow = try #require(fixture.store.workflow("local.t"))
        let recorded = AskWorkflowLogRecorder()
        let tester = AskWorkflowTester(home: fixture.home.path, record: { entry in recorded.add(entry) })
        let result = await tester.run(workflow, input: .init(query: "100 usd", selection: "sel"))
        #expect(result.succeeded, "\(result.stderr) \(result.failure ?? "")")
        #expect(result.stdout.hasPrefix("q=100 usd s=sel o=cny"))
        #expect(result.stdout.contains(#""query":"100 usd""#) && result.stdin.contains(#""query":"100 usd""#))
        #expect(result.environment["TYPEFLUX_QUERY"] == "100 usd" && result.environment["HOME"] == nil)
        #expect(result.arguments.last == "100 usd")
        #expect(recorded.entries.first?.source == .test && recorded.entries.first?.keyword == "tt")
    }

    @Test func failuresAndThingsThatCannotStart() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write(
            "local.f",
            manifest: AskWorkflowFixture.inline("local.f", keyword: "ff", script: "print -u2 bad; exit 3")
        )
        try fixture.write("local.m", manifest: AskWorkflowFixture.inline("local.m", keyword: "mm", script: "print hi",
                                                                         extra: ["command": [
                                                                             "runtime": "zsh",
                                                                             "inline": "x",
                                                                             "interpreter": "/nope/zsh"
                                                                         ]]))
        try fixture.write("local.i", manifest: ["id": "local.i", "name": "I"])
        fixture.store.reload()
        let tester = AskWorkflowTester(home: fixture.home.path)
        let failed = try await tester.run(#require(fixture.store.workflow("local.f")), input: .init(query: ""))
        #expect(failed.exitCode == 3 && failed.stderr.contains("bad") && !failed.succeeded && failed.failure == nil)
        let missing = try await tester.run(#require(fixture.store.workflow("local.m")), input: .init(query: ""))
        #expect(missing.failure?.contains("/nope/zsh") == true)
        let invalid = try await tester.run(#require(fixture.store.workflow("local.i")), input: .init(query: ""))
        #expect(invalid.failure != nil)
    }
}

/// A runner that fails before anything starts.
struct AskWorkflowFailingRunner: AskWorkflowRunning {
    var error: Error
    func run(_: AskWorkflowInvocation) -> AsyncThrowingStream<AskWorkflowRunEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

@Suite("Ask workflow tester failures")
@MainActor
struct AskWorkflowTesterFailureTests {
    @Test func spawnFailuresAndRunnerErrorsAreReported() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.s", manifest: AskWorkflowFixture.inline("local.s", keyword: "ss", script: "print hi"))
        fixture.store.reload()
        let workflow = try #require(fixture.store.workflow("local.s"))
        let spawn = AskWorkflowTester(runner: AskWorkflowFailingRunner(error: AskWorkflowRunError.spawnFailed(2)),
                                      home: fixture.home.path)
        let failed = await spawn.run(workflow, input: .init(query: ""))
        #expect(failed.failure?.isEmpty == false && !failed.succeeded)
        let other = AskWorkflowTester(runner: AskWorkflowFailingRunner(error: AskLocalError.message("broken")),
                                      home: fixture.home.path)
        #expect(await other.run(workflow, input: .init(query: "")).failure == "broken")
        #expect(AskWorkflowKeywordsForm.parseOptions("to = cny, bad, =x, a=b=c") == ["to": "cny", "a": "b=c"])
        #expect(AskWorkflowEditorSidebar.color(.ready) != AskWorkflowEditorSidebar.color(.disabled))
    }
}

/// Collects log entries from the tester's background callback.
final class AskWorkflowLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AskWorkflowLog.Entry] = []
    var entries: [AskWorkflowLog.Entry] {
        lock.withLock { stored }
    }

    func add(_ entry: AskWorkflowLog.Entry) {
        lock.withLock { stored.append(entry) }
    }
}

@Suite("Ask workflow editor model")
@MainActor
struct AskWorkflowEditorModelTests {
    private func model(_ fixture: AskWorkflowFixture,
                       api: any AskAPI = AskWorkflowScriptedAPI([])) -> AskWorkflowEditorModel {
        let assistant = makeAssistant(api)
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings, assistant: assistant,
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.staging = AskWorkflowStaging(root: fixture.home.appendingPathComponent("drafts"))
        model.watchInterval = 0
        return model
    }

    private func scriptWorkflow(_ fixture: AskWorkflowFixture,
                                script: String = "#!/bin/zsh\nprint -r -- \"hi $1\"\n") throws -> String {
        try fixture.write("local.echo", manifest: echoManifest, files: ["main.sh": script], executable: ["main.sh"])
        fixture.store.reload()
        fixture.store.trust("local.echo")
        return "local.echo"
    }

    @Test func editingAndSavingKeepsTheWorkflowTrusted() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        #expect(model.selectedFile == "main.sh" && !model.isDirty && model.problems.isEmpty)
        model.set("Echo 2", at: ["name"])
        model.setText("#!/bin/zsh\nprint bye\n", of: "main.sh")
        #expect(model.isDirty)
        #expect(model.save())
        #expect(!model.isDirty && model.workflow?.status == .ready && model.workflow?.manifest?.name == "Echo 2")
        model.addFile("lib/x.sh")
        #expect(model.selectedFile == "lib/x.sh" && model.draft?.files["lib/x.sh"] == "")
        model.addFile("../bad")
        #expect(model.message != nil)
        model.removeFile("lib/x.sh")
        #expect(model.draft?.files["lib/x.sh"] == nil)
        model.draft?.manifestText = "{\"name\":\"x\",\"id\":\"local.echo\",\"command\":{\"runtime\":\"zsh\",\"script\":\"main.sh\"},\"keywords\":[{\"keyword\":\"ec\"}]}"
        model.formatManifest()
        #expect(model.draft?.manifestText.contains("\n  ") == true)
    }

    @Test func outsideChangesReloadACleanDraftAndFlagADirtyOne() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        let id = try scriptWorkflow(fixture)
        model.open(id)
        let folder = try #require(model.folder)
        try Data("#!/bin/zsh\nprint outside\n".utf8).write(to: folder.appendingPathComponent("main.sh"))
        await model.checkOutside()
        #expect(model.draft?.files["main.sh"] == "#!/bin/zsh\nprint outside\n" && model.outsideChange == nil)
        #expect(model.needsTrust)
        model.trust()
        #expect(!model.needsTrust)
        model.setText("mine", of: "main.sh")
        try Data("theirs".utf8).write(to: folder.appendingPathComponent("main.sh"))
        await model.checkOutside()
        #expect(model.outsideChange?.disk.files["main.sh"] == "theirs")
        #expect(!model.save(), "a conflict is not written")
        model.keepMine()
        #expect(model.outsideChange == nil && model.draft?.files["main.sh"] == "mine")
        #expect(model.workflow?.status == .modified, "keeping my version over an outside change does not trust it")
        model.setText("again", of: "main.sh")
        model.loadTheirs()
        #expect(model.draft?.files["main.sh"] == "mine" && !model.isDirty)
    }

    @Test func runsShowResultsAndPointAtTheFailingLine() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture, script: "#!/bin/zsh\nprint start\nno_such_command_xyz\nexit 4\n"))
        model.testQuery = "x"
        model.runTest()
        await waitFor("test run") { !model.isTesting && !model.results.isEmpty }
        let result = try #require(model.results.last)
        #expect(result.exitCode == 4 && result.stdout.contains("start"))
        #expect(model.failureLocation?.line == 3)
        #expect(model.markers(for: "main.sh")[3] != nil && model.reveal?.line == 3)
        model.fixWithAssistant()
        #expect(model.assistant.items.first
            .map {
                if case let .user(_, text) = $0 {
                    text.contains("no_such_command_xyz")
                } else {
                    false
                }
            } == true)
    }

    @Test func untrustedWorkflowsDoNotTestRun() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.u", manifest: AskWorkflowFixture.inline("local.u", keyword: "uu", script: "print hi"))
        fixture.store.reload()
        let model = model(fixture)
        model.open("local.u")
        #expect(model.needsTrust)
        model.runTest()
        #expect(!model.isTesting && model.message != nil)
    }

    @Test func keywordsTakenElsewhereAreProblems() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        let id = try scriptWorkflow(fixture)
        try fixture.write("other", manifest: AskWorkflowFixture.inline("other", keyword: "zz", script: "print hi"))
        model.open(id)
        model.set([["keyword": "ec"], ["keyword": "zz"]], at: ["keywords"])
        #expect(model.problems.map(\.field) == ["keywords[1]"])
        #expect(model.problems(for: .keywords).count == 1)
    }

    @Test func manifestProblemsAreMarkedOnTheirLines() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        model.set("missing.sh", at: ["command", "script"])
        #expect(model.problems(for: .script).count == 1)
        let line = try #require(model.draft?.line(for: "command.script"))
        #expect(model.markers(for: "workflow.json")[line] != nil)
        #expect(model.markers(for: "main.sh").isEmpty)
    }

    @Test func proposalsApplyUndoAndDiscard() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        let first = model.submit(AskWorkflowProposal(
            summary: "a",
            manifestText: nil,
            files: ["main.sh": "print a\n"],
            deletes: []
        ))
        let second = model.submit(AskWorkflowProposal(summary: "b", manifestText: nil,
                                                      files: ["main.sh": "curl https://new.example.com\n"],
                                                      deletes: []))
        #expect(model.proposal(first.id)?.state == .superseded && model.latestProposal?.id == second.id)
        #expect(second.newRisks == [AskWorkflowRisk(kind: .network, detail: "new.example.com")])
        #expect(model.authoringDraft.files["main.sh"] == "curl https://new.example.com\n")
        model.apply(second.id)
        #expect(model.draft?.files["main.sh"] == "curl https://new.example.com\n" && model.canUndoProposal && model
            .isDirty)
        #expect(model.lastAppliedProposal == second.id)
        model.undoProposal()
        #expect(model.draft?.files["main.sh"] != "curl https://new.example.com\n" && !model.canUndoProposal)
        #expect(model.proposal(second.id)?.state == .pending && model.lastAppliedProposal == nil,
                "an undone proposal can be applied again")
        let third = model.submit(AskWorkflowProposal(summary: "c", manifestText: nil, files: [:], deletes: []))
        model.previewingProposal = third.id
        model.discard(third.id)
        #expect(model.proposal(third.id)?.state == .discarded && model.previewingProposal == nil)
        #expect(model.keywordProblem("ec") == nil && model.keywordProblem("") != nil)
    }

    @Test func assistantTestRunsAskBeforeNewRisksAndRunInStaging() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        let original = try #require(model.draft?.files["main.sh"])
        _ = model.submit(AskWorkflowProposal(summary: "",
                                             manifestText: nil,
                                             files: [
                                                 "main.sh": "#!/bin/zsh\n# https://docs.example.com\nprint -r -- \"ok $1\"\n"
                                             ],
                                             deletes: []))
        let quiet = await model.testLatestProposal([.init(query: "a")])
        #expect(quiet?.first?.stdout == "ok a\n" && model.pendingRun == nil)
        #expect(model.draft?.files["main.sh"] == original, "test runs never touch the user's files")
        let risky = model.submit(AskWorkflowProposal(summary: "", manifestText: nil,
                                                     files: ["main.sh": "#!/bin/zsh\nprint https://new.example.com\n"],
                                                     deletes: []))
        let declined = Box<[AskWorkflowTestResult]?>()
        Task { declined.value = await .some(model.testLatestProposal([.init(query: "b")])) }
        await waitFor("approval") { model.pendingRun != nil }
        #expect(model.pendingRun?.proposalID == risky.id)
        model.resolvePendingRun(false)
        await waitFor("declined") { declined.value != nil }
        #expect(declined.value == .some(nil))
        #expect(model.authoringTestFailure == .declined)
        let allowed = Box<[AskWorkflowTestResult]?>()
        Task { allowed.value = await .some(model.testLatestProposal([.init(query: "c")])) }
        await waitFor("approval again") { model.pendingRun != nil }
        model.resolvePendingRun(true)
        await waitFor("allowed") { allowed.value != nil }
        #expect(allowed.value??.first?.succeeded == true)
        #expect(model.latestProposal?.tests.count == 1)
        // Approved risks do not ask again.
        let again = await model.testLatestProposal([.init(query: "d")])
        #expect(again?.count == 1 && model.pendingRun == nil)
        model.autoTest = false
        let manual = Box<[AskWorkflowTestResult]?>()
        Task { manual.value = await .some(model.testLatestProposal([.init(query: "e")])) }
        await waitFor("manual approval") { model.pendingRun != nil }
        model.resolvePendingRun(true)
        await waitFor("manual") { manual.value != nil }
    }

    @Test func stoppingAnAssistantWaitingForApprovalPreservesTheProposal() async throws {
        let fixture = try AskWorkflowFixture()
        let api = AskWorkflowScriptedAPI([
            .tool("workflow_propose", ["summary": "new", "manifest": echoManifest,
                                       "files": [["path": "main.sh", "content": "print hello"]]]),
            .tool("workflow_test", ["inputs": [["query": "hello"]]])
        ])
        let model = model(fixture, api: api)
        try model.open(scriptWorkflow(fixture))
        model.autoTest = false
        model.assistant.send("test")
        await waitFor { model.pendingRun != nil }
        let proposalID = model.latestProposal?.id
        model.stopAssistant()
        #expect(!model.assistant.isBusy && model.pendingRun == nil && model.pendingRunContinuation == nil)
        #expect(model.latestProposal?.id == proposalID)
        model.stopAssistant()
        await waitFor { model.assistant.preview.isEmpty }
        #expect(model.latestProposal?.tests.isEmpty == true)
        model.assistant.send("continue")
        await waitFor { !model.assistant.isBusy }
        #expect(await api.results.count == 1, "the cancelled test never submits a tool result")
    }

    @Test func cancellingApprovalTaskReleasesItsContinuation() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        model.autoTest = false
        _ = model.submit(AskWorkflowProposal(summary: "test", manifestText: nil,
                                             files: ["main.sh": "print hello"], deletes: []))
        let result = Box<[AskWorkflowTestResult]?>()
        let task = Task { result.value = await .some(model.testLatestProposal([.init(query: "x")])) }
        await waitFor { model.pendingRun != nil }
        task.cancel()
        await waitFor { result.value != nil }
        #expect(result.value == .some(nil))
        #expect(model.pendingRun == nil && model.pendingRunContinuation == nil)
        #expect(model.latestProposal?.tests.isEmpty == true)
        model.resolvePendingRun(true)
        #expect(model.pendingRun == nil, "a late approval cannot revive cancelled work")
    }

    @Test func cancellationOfAnOldApprovalCannotDismissTheNextOne() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        let proposalID = UUID()
        let old = AskWorkflowEditorModel.PendingRun(proposalID: proposalID, risks: [])
        let new = AskWorkflowEditorModel.PendingRun(proposalID: proposalID, risks: [])
        let oldResult = Box<Bool>()
        let first = Task { oldResult.value = await model.waitForRunApproval(old) }
        await waitFor { model.pendingRun != nil }
        first.cancel()
        model.resolvePendingRun(false)
        // The old cancellation callback is queued on MainActor. Install the next wait
        // synchronously before yielding to it, then inspect and resolve the new wait.
        let resolver = Task { @MainActor in
            await Task.yield()
            #expect(model.pendingRun == new)
            #expect(await model.waitForRunApproval(old) == false,
                    "a second wait cannot replace the active one")
            model.resolvePendingRun(true)
        }
        let allowed = await model.waitForRunApproval(new)
        await resolver.value
        await first.value
        #expect(allowed && oldResult.value == false && model.pendingRun == nil)
    }

    @Test func anAlreadyCancelledTaskNeverRequestsApproval() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        let task = Task { @MainActor in
            await model.waitForRunApproval(.init(proposalID: UUID(), risks: []))
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(model.pendingRun == nil && model.pendingRunContinuation == nil)
    }

    @Test func aRiskyFollowUpCanFallBackToTheProposalThatRan() async throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        try model.open(scriptWorkflow(fixture))
        let first = model.submit(AskWorkflowProposal(summary: "", manifestText: nil,
                                                     files: ["main.sh": "#!/bin/zsh\nprint -r -- \"one $1\"\n"],
                                                     deletes: []))
        _ = await model.testLatestProposal([.init(query: "a")])
        #expect(model.fallbackProposal == nil, "nothing is waiting")
        let risky = model.submit(AskWorkflowProposal(summary: "", manifestText: nil,
                                                     files: ["main.sh": "#!/bin/zsh\ncurl https://new.example.com\n"],
                                                     deletes: []))
        let declined = Box<[AskWorkflowTestResult]?>()
        Task { declined.value = await .some(model.testLatestProposal([.init(query: "b")])) }
        await waitFor("approval") { model.pendingRun != nil }
        #expect(model.fallbackProposal?.id == first.id && model.proposalNumber(first.id) == 1)
        model.useFallbackProposal()
        await waitFor("declined") { declined.value != nil }
        #expect(declined.value == .some(nil) && model.pendingRun == nil)
        #expect(model.proposal(risky.id)?.state == .discarded && model.proposal(first.id)?.state == .applied)
        #expect(model.draft?.files["main.sh"]?.contains("one") == true && model.canUndoProposal)
        model.useFallbackProposal()
        #expect(model.proposal(first.id)?.state == .applied, "without a waiting run nothing changes")
    }

    @Test func generatedWorkflowsAreWrittenTestedAndInstalledOnSave() async throws {
        let fixture = try AskWorkflowFixture()
        var manifest = echoManifest
        manifest["id"] = "local.gen"
        manifest["keywords"] = [["keyword": "gg"]]
        let api = AskWorkflowScriptedAPI([
            .tool("workflow_environment", ["commands": ["ls"]]),
            .tool("workflow_propose", ["summary": "Echo", "manifest": manifest,
                                       "files": [[
                                           "path": "main.sh",
                                           "content": "#!/bin/zsh\nprint -r -- \"gen $1\"\n"
                                       ]]]),
            .tool("workflow_test", ["inputs": [["query": "x"]]]),
            .reply("Ready: type gg x.")
        ])
        let model = model(fixture, api: api)
        #expect(!model.generate(description: "  ", name: "", keyword: "gg", id: "local.gen", runtime: nil))
        #expect(model.generate(
            description: "Echo the input",
            name: "Gen",
            keyword: "gg",
            id: "local.gen",
            runtime: .zsh
        ))
        #expect(model.generation != nil && model.workflowID == nil && model.authoringWorkflowID == nil)
        await waitFor("generation") { !model.assistant.isBusy && model.latestProposal?.tests.isEmpty == false }
        let sends = await api.sends
        #expect(sends.first?.text.contains("Echo the input") == true && sends.first?.text.contains("zsh") == true)
        #expect(model.latestProposal?.tests.first?.stdout == "gen x\n")
        #expect(model.store.workflow("local.gen") == nil, "nothing is installed before saving")
        model.runTest()
        #expect(model.message != nil)
        #expect(model.assistant.items.contains {
            if case let .tool(_, summary, _) = $0 {
                summary.hasSuffix("workflow.json, main.sh")
            } else {
                false
            }
        })
        #expect(model.canSaveGenerated)
        #expect(model.saveGenerated())
        #expect(!model.saveGenerated() && !model.canSaveGenerated, "a saved workflow is no longer generated")
        #expect(model.generation == nil && model.workflowID == "local.gen" && model.workflow?.status == .ready)
        #expect(model.draft?.files["main.sh"]?.contains("gen") == true)
        #expect(!model.generate(description: "again", name: "", keyword: "gg", id: "local.gen2", runtime: nil))
    }

    @Test func withoutAKeywordTheAssistantPicksOne() async throws {
        let fixture = try AskWorkflowFixture()
        let api = AskWorkflowScriptedAPI([.reply("Which keyword?")])
        let model = model(fixture, api: api)
        #expect(model.generate(description: "Count words", name: "", keyword: "", id: "local.workflow",
                               runtime: nil))
        await waitFor("reply") { !model.assistant.isBusy }
        let sends = await api.sends
        #expect(model.assistant.items.first == .user(id: sends.first?.id ?? "", text: "Count words"),
                "the conversation shows what the user typed")
        #expect(sends.first?.text.contains("workflow_check_keyword") == true)
        #expect(sends.first?.text.contains("local.workflow") == true)
        #expect(model.draft?.manifest?.keywords.isEmpty == true && model.draft?.manifest?.name == "local.workflow")
        #expect(!model.canSaveGenerated, "nothing to save before a proposal")
        model.discardGeneration()
        #expect(!model.generate(description: "x", name: "", keyword: "a b", id: "local.w2", runtime: nil),
                "a keyword that was given must be valid")
    }

    @Test func outsideRequestsNeverDropUnsavedEdits() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        let id = try scriptWorkflow(fixture)
        model.navigate(to: nil)
        #expect(model.workflowID == id)
        model.setText("unsaved", of: "main.sh")
        model.navigate(to: id, path: "workflow.json", line: 3)
        #expect(model.draft?.files["main.sh"] == "unsaved" && model.selectedFile == "workflow.json")
        #expect(model.reveal?.line == 3 && model.configMode == .json)
        #expect(!model.create(.shellText, name: "Other", keyword: "ot", id: "local.ot"))
        #expect(model.workflowID == id && model.draft?.files["main.sh"] == "unsaved")
        model.navigate(to: "md")
        #expect(model.message == L("ask.workflow.editor.saveBeforeSwitch"))
        _ = model.save()
        model.message = nil
        model.navigate(to: id, path: "nope.sh")
        #expect(model.message == nil)
    }

    @Test func createDuplicateAndDelete() throws {
        let fixture = try AskWorkflowFixture()
        let model = model(fixture)
        #expect(model.create(.shellText, name: "Shell", keyword: "sh1", id: "local.sh1"))
        #expect(model.workflowID == "local.sh1")
        #expect(!model.create(.shellText, name: "Shell", keyword: "sh1", id: "local.sh2"))
        #expect(model.duplicate("local.sh1", name: "Copy", keyword: "sh2", id: "local.sh2"))
        #expect(model.workflowID == "local.sh2" && model.workflow?.status == .ready)
        #expect(!model.duplicate("local.none", name: "x", keyword: "zz", id: "local.zz"))
        model.search = "sh2"
        #expect(model.filteredWorkflows.map(\.id) == ["local.sh2"])
        model.delete()
        #expect(model.workflowID == nil && fixture.store.workflow("local.sh2") == nil)
        model.open("local.missing")
        #expect(model.message != nil)
        model.close()
        #expect(model.draft == nil)
    }
}

@Suite("Ask workflow launcher actions")
@MainActor
struct AskWorkflowLauncherActionTests {
    @Test func failedRunsOfferEditingAndFixing() async throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.e", manifest: echoManifest.merging(["id": "local.e"]) { $1 },
                          files: ["main.sh": "#!/bin/zsh\nno_such_command_xyz\n"], executable: ["main.sh"])
        fixture.store.reload()
        fixture.store.trust("local.e")
        let workflow = try #require(fixture.store.workflow("local.e"))
        let plugin = AskWorkflowPlugin(workflow: workflow, home: fixture.home.path)
        let request = AskPluginRequest(text: "q", origin: .argument, keyword: plugin.defaultKeywords[0], options: [:],
                                       interfaceLanguage: .english, selection: nil)
        let plan = await plugin.plan(request)
        do {
            _ = try await plugin.run(request, plan: plan) { _ in }
            Issue.record("expected a failure")
        } catch let failure as AskPluginFailure {
            guard case let .editWorkflow(id, path, line) = failure.action(for: .commandE)?.kind else {
                Issue.record("no edit action"); return
            }
            #expect(id == "local.e" && path == "main.sh" && line == 2)
            #expect(failure.actions
                .contains {
                    if case .fixWorkflow("local.e", "q", _) = $0.kind {
                        true
                    } else {
                        false
                    }
                })
        }
        let blocked = AskWorkflowPlugin(workflow: AskWorkflow.load(
            folder: workflow.folder,
            trusted: nil,
            disabled: false
        ))
        let blockedPlan = await blocked.plan(request)
        await #expect(throws: AskPluginFailure.self) { try await blocked.run(request, plan: blockedPlan) { _ in } }
        #expect(blocked.editActions().count == 1)
        #expect(blocked.editActions(query: "q", stderr: "e", reason: "r").map(\.shortcut) == [
            .commandE,
            .commandC,
            nil
        ])
    }

    @Test func commandEIsAKeyAndActionsOpenTheEditor() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: 14
        ))
        #expect(AskCommandKey(event) == .commandE)
        let fixture = try AskTestFixture()
        var edited: (String, String?, Int?)?
        var fixed: (String, String, String)?
        fixture.model.editWorkflow = { edited = ($0, $1, $2) }
        fixture.model.fixWorkflow = { fixed = ($0, $1, $2) }
        #expect(fixture.model.performPluginAction(AskPluginAction(
            kind: .editWorkflow(id: "w", path: "main.py", line: 3),
            title: "",
            symbol: ""
        )) == .close)
        #expect(edited?.0 == "w" && edited?.1 == "main.py" && edited?.2 == 3)
        #expect(fixture.model.performPluginAction(AskPluginAction(kind: .fixWorkflow(id: "w", query: "q", error: "e"),
                                                                  title: "", symbol: "")) == .close)
        #expect(fixed?.0 == "w" && fixed?.1 == "q" && fixed?.2 == "e")
        let failure = AskPluginFailure(
            message: "m",
            actions: [AskPluginAction(kind: .compare, title: "", symbol: "", shortcut: .commandE)]
        )
        #expect(failure.action(for: .commandE) != nil && failure.action(for: .commandR) == nil)
    }
}

@Suite("Ask workflow editor presentation")
@MainActor
struct AskWorkflowEditorPresentationTests {
    private func open(_ fixture: AskWorkflowFixture, id: String,
                      script: String = "#!/bin/zsh\nif true; then\n  print hi\nfi\n") throws -> AskWorkflowEditorModel {
        try fixture.write(id, manifest: echoManifest.merging(["id": id]) { $1 }, files: ["main.sh": script],
                          executable: ["main.sh"])
        fixture.store.reload()
        fixture.store.trust(id)
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings,
                                           assistant: makeAssistant(AskWorkflowScriptedAPI([])),
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.watchInterval = 0
        model.open(id)
        return model
    }

    @Test func unsavedLabelsAndIndentation() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, id: "local.labels")
        #expect(model.unsavedLabel == nil)
        model.setText("#!/bin/zsh\r\nif true; then\n\tprint hi\nfi\n", of: "main.sh")
        #expect(model.unsavedLabel == L("ask.workflow.editor.unsavedFile", "main.sh"))
        model.set("Other", at: ["name"])
        #expect(model.unsavedLabel == L("ask.workflow.editor.unsavedFiles", 2))
        let config = try open(fixture, id: "local.config")
        config.set("Other", at: ["name"])
        #expect(config.unsavedLabel == L("ask.workflow.editor.unsavedFile", L("ask.workflow.editor.config")))
        #expect(AskWorkflowCodeIndentation.width(of: "x") == 4)
        #expect(AskWorkflowCodeIndentation.width(of: "a\n  b\n    c") == 2)
        #expect(AskWorkflowCodeIndentation.width(of: "a\n    b\n   c") == 4)
    }

    @Test func historyMergesTestRunsAndLauncherRunsNewestFirst() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, id: "local.history")
        defer { AskWorkflowLog.shared.clear("local.history") }
        let now = Date()
        model.results = [
            AskWorkflowTestResult(input: .init(query: "a"), exitCode: 0, stdout: "", stderr: "", duration: 0.1,
                                  date: now.addingTimeInterval(-30)),
            AskWorkflowTestResult(input: .init(query: ""), exitCode: 2, stdout: "", stderr: "", duration: 0.2,
                                  date: now.addingTimeInterval(-90))
        ]
        AskWorkflowLog.shared.add(.init(workflowID: "local.history", keyword: "ec", date: now, duration: 0.3,
                                        exitCode: 0, timedOut: true, stderr: ""))
        AskWorkflowLog.shared.add(.init(workflowID: "local.history", keyword: "ec", date: now, duration: 0.3,
                                        exitCode: 0, timedOut: false, stderr: "", source: .test))
        let history = model.history
        #expect(history.map(\.title) == [
            L("ask.workflow.editor.test.sourceLauncher", "ec"),
            L("ask.workflow.editor.test.sourceTest", "a"),
            L("ask.workflow.editor.test.sourceTest", "—")
        ])
        #expect(history.map(\.succeeded) == [false, true, false])
        #expect(AskWorkflowEditorModel
            .relative(now.addingTimeInterval(-5), now: now) == L("ask.workflow.editor.justNow"))
        let hourAgo = AskWorkflowEditorModel.relative(now.addingTimeInterval(-3600), now: now)
        #expect(!hourAgo.isEmpty && hourAgo != L("ask.workflow.editor.justNow"))
    }

    @Test func outsideStatsAndTrustedHash() async throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, id: "local.outside")
        let label = try #require(model.trustedHashLabel)
        #expect(label.count == 9 && label.contains("…"))
        #expect(model.outsideStats == nil)
        model.setText("#!/bin/zsh\nprint mine\n", of: "main.sh")
        let folder = try #require(model.folder)
        try Data("#!/bin/zsh\nprint theirs\nprint more\n".utf8).write(to: folder.appendingPathComponent("main.sh"))
        await model.checkOutside()
        let stats = try #require(model.outsideStats)
        #expect(stats.paths == ["main.sh"] && stats.added == 2 && stats.removed == 1)
        fixture.settings.askWorkflowTrust = [:]
        #expect(model.trustedHashLabel == nil)
    }

    @Test func problemsAndScriptSuggestions() throws {
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, id: "local.fix")
        #expect(model.scriptSuggestion == nil)
        #expect(model.proposalNumber(UUID()) == 1)
        model.set("run.sh", at: ["command", "script"])
        #expect(model.scriptSuggestion == "main.sh")
        let problem = try #require(model.problems.first { $0.field == "command.script" })
        model.step = .keywords
        model.revealProblem(problem)
        #expect(model.step == .output && model.configMode == .json)
        #expect(model.reveal?.path == AskWorkflowManifest.fileName && model.reveal?.line == model.draft?
            .line(for: "command.script"))
        model.revealProblem(.init(field: "keywords[0]", message: "x"))
        #expect(model.step == .keywords)
        model.applyScriptSuggestion()
        #expect(model.draft?.manifest?.command.script == "main.sh" && model.scriptSuggestion == nil)
        model.applyScriptSuggestion()
        model.set("tool.py", at: ["command", "script"])
        #expect(model.scriptSuggestion == nil, "nothing else runs as python")
    }

    @Test func runtimeDescriptionsComeFromTheProbe() async throws {
        let report = #"{"runtimes": {"zsh": "zsh 5.9 · /bin/zsh"}, "commands": {"jq": "/usr/bin/jq", "nope": null}}"#
        #expect(AskWorkflowEditorModel.runtimeDescription(report, name: "zsh", title: "Zsh") == "zsh 5.9 · /bin/zsh")
        #expect(AskWorkflowEditorModel.runtimeDescription(report, name: "jq", title: "JQ") == "JQ · /usr/bin/jq")
        #expect(AskWorkflowEditorModel.runtimeDescription(report, name: "nope", title: "X")
            == L("ask.workflow.missingRuntime", "nope"))
        #expect(AskWorkflowEditorModel.runtimeDescription(report, name: nil, title: "Exec") == "Exec")
        #expect(AskWorkflowEditorModel.runtimeDescription("not json", name: "zsh", title: "Zsh") == "Zsh")
        let fixture = try AskWorkflowFixture()
        let model = try open(fixture, id: "local.runtime")
        await waitFor("runtime info") { model.runtimeInfo != nil }
        #expect(model.runtimeInfo?.contains("zsh") == true)
    }
}

@Suite("Ask workflow editor simplification")
@MainActor
struct AskWorkflowEditorSimplificationTests {
    @Test func toolStepsFoldIntoOneLineBetweenMessages() {
        let first = UUID(), second = UUID(), third = UUID(), proposal = UUID()
        let entries = AskWorkflowAssistantPanel.entries([
            .user(id: "u", text: "hi"),
            .tool(id: first, summary: "read", failed: false),
            .tool(id: second, summary: "wrote", failed: false),
            .proposal(proposal),
            .tool(id: third, summary: "tested", failed: true),
            .reply(id: "r", text: "done")
        ])
        #expect(entries == [
            .item(.user(id: "u", text: "hi")),
            .steps(id: "steps-" + first.uuidString, summaries: ["read", "wrote"]),
            .item(.proposal(proposal)),
            .steps(id: "steps-" + third.uuidString, summaries: ["tested"]),
            .item(.reply(id: "r", text: "done"))
        ])
        #expect(entries.map(\.id) == ["u", "steps-" + first.uuidString, "proposal-" + proposal.uuidString,
                                      "steps-" + third.uuidString, "r"])
        #expect(AskWorkflowAssistantPanel.entries([]).isEmpty)
    }

    @Test func theStatusBarOnlyShowsWithSomethingToSay() throws {
        let fixture = try AskWorkflowFixture()
        try fixture.write("local.s", manifest: AskWorkflowFixture.inline("local.s", keyword: "ss", script: "print hi"))
        fixture.store.reload()
        fixture.store.trust("local.s")
        let model = AskWorkflowEditorModel(store: fixture.store, settings: fixture.settings,
                                           assistant: makeAssistant(AskWorkflowScriptedAPI([])),
                                           tester: AskWorkflowTester(home: fixture.home.path))
        model.watchInterval = 0
        model.open("local.s")
        #expect(!AskWorkflowStatusBar.hasNews(model))
        model.results = [AskWorkflowTestResult(input: .init(query: ""), exitCode: 1, stdout: "", stderr: "x",
                                               duration: 0.1)]
        model.step = .script
        #expect(AskWorkflowStatusBar.hasNews(model))
        model.step = .keywords
        #expect(!AskWorkflowStatusBar.hasNews(model))
        model.set("bad id", at: ["id"])
        #expect(AskWorkflowStatusBar.hasNews(model))
    }
}

@Suite("Ask workflow code view selection")
struct AskWorkflowCodeViewSelectionTests {
    @Test func aSelectionPastTheNewEndBecomesACaretAtTheEnd() {
        let past = [NSValue(range: NSRange(location: 40, length: 2))]
        #expect(AskWorkflowCodeView.keptSelection(past, length: 10).map(\.rangeValue) == [NSRange(location: 10, length: 0)])
        let inside = [NSValue(range: NSRange(location: 2, length: 3)), NSValue(range: NSRange(location: 9, length: 5))]
        #expect(AskWorkflowCodeView.keptSelection(inside, length: 10).map(\.rangeValue) == [NSRange(location: 2, length: 3)])
        #expect(AskWorkflowCodeView.keptSelection([], length: 0).map(\.rangeValue) == [NSRange(location: 0, length: 0)])
    }
}
