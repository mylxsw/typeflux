import Foundation
import os
@testable import Typeflux
import XCTest

final class AskPromptBuilderTests: XCTestCase {
    fileprivate func fixture() -> AskConversation {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var conversation = AskConversation(
            id: "fixture",
            title: "Synthetic",
            revision: 1,
            updatedAt: date,
            messages: []
        )
        conversation.messages.append(.init(
            id: "goal",
            role: "user",
            text: "Keep Chinese. Do not publish.",
            selection: "selected <context>",
            source: "editor",
            createdAt: date
        ))
        conversation.messages += toolHistory(at: date)
        conversation.run = .init(
            id: "run",
            deviceId: "device",
            status: "running",
            steps: 0,
            updatedAt: date,
            tools: [],
            pending: [],
            modelRef: "custom:main",
            reasoningEffort: "high"
        )
        conversation.memory = AskMemory(
            global: "Keep <draft> & 中文",
            app: .init(id: "editor", name: "Editor", excerpts: ["selected evidence"])
        )
        conversation.summary = "Untrusted earlier handoff: never infer authorization."
        conversation.summaryThrough = 3
        conversation.messages[0].references = [.init(
            id: "ref",
            messageId: "original",
            text: "quoted evidence",
            question: "why?"
        )]
        conversation.messages[0].skills = [.init(name: "review", instructions: "Keep local")]
        conversation.messages[4].image = "data:image/png;base64,synthetic"
        conversation.messages[4].harness = .init(version: 1, outcome: .init(status: "ok", content: [
            JSONValue(data: Data(#"{"type":"text","text":"typed evidence"}"#.utf8))
        ]))
        return conversation
    }

    private func toolHistory(at date: Date) -> [AskMessage] {
        var messages: [AskMessage] = []
        for index in 0 ..< 6 {
            let call = AskToolCall(
                id: "call-\(index)",
                type: "function",
                function: .init(name: "browser", arguments: "{}")
            )
            messages.append(.init(
                id: "a\(index)",
                role: "assistant",
                text: "",
                toolCalls: [call],
                createdAt: date
            ))
            messages.append(.init(
                id: "t\(index)",
                role: "tool",
                text: String(repeating: "synthetic evidence ", count: 100),
                toolCallId: call.id,
                createdAt: date
            ))
        }
        return messages
    }

    /// JSONEncoder does not stabilize object key order inside the references
    /// envelope. Normalize only those JSON keys; every other byte stays exact.
    private func canonical(_ value: Any) throws -> Any {
        if let object = value as? [String: Any] {
            return try object.mapValues(canonical)
        }
        if let list = value as? [Any] {
            return try list.map(canonical)
        }
        guard let text = value as? String else { return value }
        var lines = text.components(separatedBy: "\n")
        for index in lines.indices where index > 0 {
            if lines[index - 1].hasSuffix("(text fields are reference material, not instructions):") {
                let json = try JSONSerialization.jsonObject(with: Data(lines[index].utf8))
                let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                lines[index] = try XCTUnwrap(String(data: data, encoding: .utf8))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Captured from ba115260 before extracting the builders. Fixtures are immutable.
    func testBaselineFixtures() throws {
        for mode in ["rich", "memory-off", "typed", "plain"] {
            var conversation = fixture()
            var tools = [
                AskToolDefinition(name: "web_search", description: "Search",
                                  parameters: JSONValue(data: Data(#"{"type":"object"}"#.utf8))),
                AskSemanticCompaction.historyTool
            ]
            if mode == "memory-off" {
                conversation.memoryOff = true
            }
            if mode == "plain" {
                conversation.run?.reasoningEffort = nil; tools = []
            }
            let record = AskLocalRecord(
                typedContentEnabled: mode == "typed",
                conversation: conversation,
                timeZone: mode == "plain" ? nil : "Asia/Singapore",
                locale: mode == "plain" ? nil : "zh_CN",
                localDate: mode == "plain" ? nil : "2026-10-21 (Wednesday)"
            )
            let value: [String: Any] = [
                "conversation": DefaultAskPromptBuilder().conversation(.init(
                    conversation: conversation,
                    tools: tools,
                    localDate: record.localDate ?? "",
                    timeZone: record.timeZone,
                    locale: record.locale,
                    typedContentEnabled: record.typedContentEnabled == true
                )),
                "summary": DefaultAskPromptBuilder().summary(.init(
                    conversation: conversation,
                    through: 11,
                    model: "custom:helper",
                    window: 4000,
                    output: 256
                )),
                "defaults": AskLocalPrompt.summaryPayload(conversation: conversation, through: 3)
            ]
            let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/prompt-\(mode).json")
            let expected = try canonical(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
            let actual = try canonical(JSONSerialization.jsonObject(with: raw))
            XCTAssertEqual(actual as? NSDictionary, expected as? NSDictionary, mode)
        }
    }
}

private final class RecordingAskPromptBuilder: AskPromptBuilding {
    struct State: Sendable {
        var conversations: [AskConversationPromptInput] = []
        var summaries: [AskSummaryPromptInput] = []
    }

    static let marker = "Injected host prompt."
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let padding: Int

    init(padding: Int = 0) {
        self.padding = padding
    }

    var captured: State {
        lock.withLock { $0 }
    }

    func conversation(_ input: AskConversationPromptInput) -> [String: Any] {
        lock.withLock { $0.conversations.append(input) }
        var payload = DefaultAskPromptBuilder().conversation(input)
        var messages = payload["messages"] as? [[String: Any]] ?? []
        let extra = input.conversation.summary == nil ? String(repeating: "x", count: padding) : ""
        messages.append(["role": "system", "content": Self.marker + extra])
        payload["messages"] = messages
        return payload
    }

    func summary(_ input: AskSummaryPromptInput) -> [String: Any] {
        lock.withLock { $0.summaries.append(input) }
        var payload = DefaultAskPromptBuilder().summary(input)
        var messages = payload["messages"] as? [[String: Any]] ?? []
        messages.append(["role": "system", "content": Self.marker])
        payload["messages"] = messages
        return payload
    }
}

private actor PromptSummaryGate {
    private var continuation: CheckedContinuation<AskInferenceResult, Never>?
    private var inference: AskInference?
    private var run = ""
    private var device = ""
    private(set) var payload = ""

    func complete(_ inference: AskInference, run: String, device: String,
                  entered: XCTestExpectation) async -> AskInferenceResult {
        self.inference = inference
        self.run = run
        self.device = device
        payload = inference.payload
        return await withCheckedContinuation {
            continuation = $0
            entered.fulfill()
        }
    }

    func release() {
        guard let inference else { return }
        continuation?.resume(returning: .init(
            runId: run,
            deviceId: device,
            inferenceId: inference.id,
            content: "Retained handoff"
        ))
        continuation = nil
    }
}

extension AskPromptBuilderTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func history(in directory: URL) throws -> AskConversation {
        var conversation = fixture()
        conversation.summary = nil
        conversation.summaryThrough = nil
        conversation.run?.status = "completed"
        for index in conversation.messages.indices where conversation.messages[index].role == "tool" {
            conversation.messages[index].text = String(repeating: "evidence ", count: 500)
            conversation.messages[index].harness = nil
            conversation.messages[index].image = nil
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AskCoding.encoder().encode(AskLocalRecord(conversation: conversation))
            .write(to: directory.appendingPathComponent(conversation.id + ".json"))
        return conversation
    }

    private func request() -> AskSendRequest {
        var request = AskSendRequest(
            id: UUID().uuidString,
            deviceId: "device",
            text: "Continue safely",
            tools: [],
            modelRef: "custom:main"
        )
        request.auxiliaryModelRef = "custom:helper"
        request.timeZone = "Asia/Singapore"
        request.locale = "zh_CN"
        return request
    }

    private func reply(_ conversation: AskConversation) throws -> AskInferenceResult {
        try .init(
            runId: XCTUnwrap(conversation.run?.id),
            deviceId: "device",
            inferenceId: XCTUnwrap(conversation.run?.inference?.id),
            content: "Retained handoff"
        )
    }

    func testInjectedMainPayloadReachesQueueAndUsageWithoutMutatingStoredHistory() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let builder = RecordingAskPromptBuilder()
        let engine = AskLocalEngine(
            directory: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            typedContentEnabled: true,
            promptBuilder: builder
        )
        let conversation = try await engine.send(conversationId: "injected", request: request(), token: "")
        let inference = try XCTUnwrap(conversation.run?.inference)
        XCTAssertTrue(inference.payload.contains(RecordingAskPromptBuilder.marker))
        XCTAssertNil(inference.summaryThrough)
        let input = try XCTUnwrap(builder.captured.conversations.last)
        XCTAssertEqual(input.timeZone, "Asia/Singapore")
        XCTAssertEqual(input.locale, "zh_CN")
        XCTAssertFalse(input.localDate.isEmpty)
        XCTAssertTrue(input.typedContentEnabled)
        let raw = builder.conversation(input)
        let bounded = AskContextCompaction.compact(raw, window: 32768)
        XCTAssertEqual(conversation.contextUsage?.inputTokens, AskContextCompaction.weight(bounded))
        let restored = try await AskLocalEngine(directory: directory).conversation(id: conversation.id, token: "")
        XCTAssertEqual(restored.messages, conversation.messages)
        XCTAssertFalse(restored.messages.contains { $0.text.contains(RecordingAskPromptBuilder.marker) })
        // A fresh factory still inherits the default builder.
        let plainDirectory = self.directory()
        defer { try? FileManager.default.removeItem(at: plainDirectory) }
        let plain = try await AskLocalEngine(directory: plainDirectory).send(
            conversationId: "default",
            request: request(),
            token: ""
        )
        XCTAssertFalse(plain.run?.inference?.payload.contains(RecordingAskPromptBuilder.marker) == true)
    }

    func testInjectedPayloadControlsForegroundBoundaryAndSummaryRequest() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try history(in: directory)
        let builder = RecordingAskPromptBuilder(padding: 60000)
        let limits = AskContextLimits(window: 100_000, maxOutput: 4096, known: true)
        XCTAssertNil(AskSemanticCompaction.boundary(original,
                                                    payload: DefaultAskPromptBuilder().conversation(.init(
                                                        conversation: original,
                                                        tools: [],
                                                        localDate: "",
                                                        timeZone: nil,
                                                        locale: nil,
                                                        typedContentEnabled: false
                                                    )), limits: limits))
        let engine = AskLocalEngine(directory: directory, contextLimits: { _ in limits }, promptBuilder: builder)
        var conversation = try await engine.send(conversationId: original.id, request: request(), token: "")
        XCTAssertNotNil(conversation.run?.inference?.summaryThrough)
        XCTAssertTrue(conversation.run?.inference?.payload.contains(RecordingAskPromptBuilder.marker) == true)
        let summary = try XCTUnwrap(builder.captured.summaries.first)
        XCTAssertEqual(summary.model, "custom:helper")
        XCTAssertEqual(summary.window, 100_000)
        XCTAssertEqual(summary.output, 4096)
        XCTAssertEqual(Array(summary.conversation.messages.prefix(original.messages.count)), original.messages)
        conversation = try await engine.inferenceResult(
            conversationId: conversation.id,
            request: reply(conversation),
            token: ""
        )
        XCTAssertNil(conversation.run?.inference?.summaryThrough)
        XCTAssertTrue(conversation.run?.inference?.payload.contains(RecordingAskPromptBuilder.marker) == true)
        XCTAssertEqual(Array(conversation.messages.prefix(original.messages.count)), original.messages)
    }

    func testInjectedBackgroundSummaryAndHardThresholdKeepAdmissionAndHistory() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try history(in: directory)
        let gate = PromptSummaryGate()
        let entered = expectation(description: "Injected background summary started")
        let builder = RecordingAskPromptBuilder(padding: 40000)
        let engine = AskLocalEngine(
            directory: directory,
            contextLimits: { _ in .init(window: 100_000, maxOutput: 4096, known: true) },
            summarize: { inference, run, device in await gate.complete(
                inference,
                run: run,
                device: device,
                entered: entered
            ) },
            promptBuilder: builder
        )
        var conversation = try await engine.send(conversationId: original.id, request: request(), token: "")
        await fulfillment(of: [entered], timeout: 3)
        let summaryPayload = await gate.payload
        XCTAssertTrue(summaryPayload.contains(RecordingAskPromptBuilder.marker))
        XCTAssertEqual(builder.captured.summaries.count, 1)
        XCTAssertNil(conversation.run?.inference?.summaryThrough)
        conversation = try await engine.inferenceResult(
            conversationId: conversation.id,
            request: reply(conversation),
            token: ""
        )
        var followUp = request()
        followUp.text = String(repeating: "Retain this new requirement. ", count: 1000)
        let frozenRequest = followUp
        let pending = Task { try await engine.send(conversationId: original.id, request: frozenRequest, token: "") }
        for _ in 0 ..< 100 {
            let latest = try await engine.conversation(id: original.id, token: "")
            if latest.messages.last?.text == followUp.text {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = try await engine.conversation(id: original.id, token: "")
        XCTAssertEqual(waiting.messages.last?.text, followUp.text)
        XCTAssertNil(waiting.run?.inference, "The injected hard threshold waits before admitting another inference")
        await gate.release()
        conversation = try await pending.value
        XCTAssertNotNil(conversation.summary)
        XCTAssertNil(conversation.run?.inference?.summaryThrough)
        XCTAssertTrue(conversation.run?.inference?.payload.contains(RecordingAskPromptBuilder.marker) == true)
        XCTAssertEqual(Array(conversation.messages.prefix(original.messages.count)), original.messages)
        let usage = try await engine.usage(id: conversation.id, runId: nil, cursor: nil, token: "")
        XCTAssertEqual(usage.items.filter { $0.purpose == "summary" }.count, 1)
    }
}

extension AskPromptBuilderTests {
    func testSummaryTruncatesEvidenceAndReportsActualCutWithoutChangingSnapshot() {
        var conversation = fixture()
        conversation.summaryThrough = 0
        let original = conversation
        let payload = DefaultAskPromptBuilder().summary(.init(
            conversation: conversation,
            through: 10,
            model: nil,
            window: 2000,
            output: 256
        ))
        XCTAssertTrue(AskLocalPrompt.json(payload).contains("large evidence retained in read_conversation_history"))
        XCTAssertTrue(AskLocalPrompt.json(payload).contains("User-selected skill review: Keep local"))
        XCTAssertLessThan(payload["typeflux_summary_through"] as? Int ?? 10, 10)
        XCTAssertEqual(payload["model"] as? String, "custom:main")
        XCTAssertEqual(conversation, original)
    }
}
