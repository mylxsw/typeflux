import Testing
import TypefluxChat
@testable import TypefluxIOS

struct ChatTranscriptTests {
    @Test func `consecutive calls become one card with correctly matched out of order results`() {
        let first = call("a"), second = call("b")
        let conversation = document([
            message("user", role: "user", text: "Find it"),
            message("one", calls: [first]), result("b"), result("a"), message("two", calls: [second]),
            message("answer", text: "Found it")
        ])
        let items = ChatTranscript.items(conversation)
        #expect(items.count == 3)
        guard case let .activity(group) = items[1] else { Issue.record("Missing group"); return }
        #expect(group.messages.map(\.id) == ["one", "two"])
        #expect(group.steps.map(\.id) == ["a", "b"])
        #expect(group.steps.map { $0.result?.toolCallId } == ["a", "b"])
        #expect(group.status == .done)
        #expect(items.map(\.id) == ["message/user", "activity/one", "message/answer"])
    }

    @Test func `user messages split activity groups and orphan results remain visible`() {
        let items = ChatTranscript.items(document([
            message("one", calls: [call("a")]), result("a"),
            message("user", role: "user"), message("two", calls: [call("b")]),
            result("missing"), message("bare", role: "tool", text: "Output without a call id")
        ]))
        #expect(items.count == 5)
        #expect(items.map(\.id) == [
            "activity/one",
            "message/user",
            "activity/two",
            "message/result-missing",
            "message/bare"
        ])
    }

    @Test func `active latest card expands while historical incomplete calls stay interrupted`() {
        let items = ChatTranscript.items(document([
            message("old", calls: [call("old")]), message("user", role: "user"), message("live", calls: [call("live")])
        ], run: run("running")))
        guard case let .activity(old) = items[0], case let .activity(live) = items[2] else {
            Issue.record("Missing groups"); return
        }
        #expect(old.status == .stopped)
        #expect(live.status == .running)
        #expect(live.steps.first?.status == .running)
    }

    @Test(arguments: ["waiting_tool", "waiting_inference"])
    func `desktop waits preserve pending calls without duplicates`(_ status: String) {
        let items = ChatTranscript.items(document([message("live", calls: [call("a")])],
                                                  run: run(status, pending: [call("a"), call("b")])))
        #expect(items.count == 1)
        guard case let .activity(group) = items[0] else { Issue.record("Missing group"); return }
        #expect(group.steps.map(\.id) == ["a", "b"])
        #expect(group.status == .waiting)
        #expect(group.steps.allSatisfy { $0.status == .waiting })
    }

    @Test func `pending calls without assistant message still show an activity`() {
        let items = ChatTranscript.items(document(
            [message("user", role: "user")],
            run: run("running", pending: [call("a")])
        ))
        #expect(items.count == 2)
        guard case let .activity(group) = items[1] else { Issue.record("Missing pending card"); return }
        #expect(group.id == "pending/run")
        #expect(group.messages.isEmpty)
        #expect(group.steps.first?.id == "a")
    }

    @Test(arguments: ["cancelled", "completed", "failed"])
    func `terminal runs never show missing tool output as still running`(_ status: String) {
        let items = ChatTranscript.items(document(
            [message("one", calls: [call("a")])],
            run: run(status, pending: [call("b")])
        ))
        #expect(items.count == 1)
        guard case let .activity(group) = items[0] else { Issue.record("Missing group"); return }
        #expect(group.status == .stopped)
        #expect(group.steps.first?.status == .stopped)
    }

    @Test func `failed results are visible and completed results win over active pending status`() {
        let messages = [message("one", calls: [call("a"), call("b")]), result("a", error: true), result("b")]
        let completed = ChatTranscript.items(document(messages))
        guard case let .activity(group) = completed[0] else { Issue.record("Missing group"); return }
        #expect(group.status == .failed)
        #expect(group.steps.map(\.status) == [.failed, .done])
        let active = ChatTranscript.items(document(messages, run: run("running")))
        guard case let .activity(live) = active[0] else { Issue.record("Missing group"); return }
        #expect(live.status == .running)
        #expect(live.steps.map(\.status) == [.failed, .done])
    }

    @Test func `newest duplicate result is used without crashing`() {
        let items = ChatTranscript.items(document([
            message("one", calls: [call("a")]),
            result("a", error: true),
            result("a")
        ]))
        guard case let .activity(group) = items[0] else { Issue.record("Missing group"); return }
        #expect(group.status == .done)
    }

    @Test func `preview survives interruption and is hidden once committed to transcript`() {
        var conversation = document([], run: run("failed"))
        conversation.run?.preview = "Partial answer"
        #expect(ChatTranscript.preview(conversation) == "Partial answer")
        conversation.messages = [message("answer", text: "Partial answer")]
        #expect(ChatTranscript.preview(conversation) == nil)
        conversation.run?.preview = " \n "
        #expect(ChatTranscript.preview(conversation) == nil)
        #expect(ChatTranscript.preview(document([])) == nil)
    }

    @Test func `tool details use readable targets and malformed arguments are safe`() {
        #expect(ChatToolPresentation
            .detail(call("a", arguments: #"{"query":"Swift","url":"https://example.com"}"#)) == "Swift")
        #expect(ChatToolPresentation.detail(call("a", arguments: #"{"query":"","path":"notes.md"}"#)) == "notes.md")
        #expect(ChatToolPresentation.detail(call("a", arguments: "partial{")) == nil)
        #expect(ChatToolPresentation.detail(call("a", arguments: "[]")) == nil)
        #expect(ChatToolPresentation.detail(call("a")) == nil)
    }

    @Test(arguments: ["web_search", "web_fetch", "research", "files", "project_files", "run_code", "project_terminal",
                      "browser", "computer", "memory", "skill", "update_plan", "artifact", "custom_tool"])
    func `tool presentation supplies readable titles and symbols`(_ name: String) {
        let tool = call("a", name: name)
        #expect(!ChatToolPresentation.title(tool).isEmpty)
        #expect(!ChatToolPresentation.symbol(tool).isEmpty)
        #expect(ChatToolPresentation.title(tool) != name)
    }

    private func call(_ id: String, name: String = "web_search", arguments: String = "{}") -> ChatToolCall {
        ChatToolCall(id: id, function: .init(name: name, arguments: arguments))
    }

    private func message(_ id: String, role: String = "assistant", text: String = "",
                         calls: [ChatToolCall]? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, toolCalls: calls)
    }

    private func result(_ id: String, error: Bool = false) -> ChatMessage {
        ChatMessage(id: "result-" + id, role: "tool", text: "Result " + id, toolCallId: id, isError: error)
    }

    private func document(_ messages: [ChatMessage], run: ChatRun? = nil) -> ChatConversation {
        ChatConversation(id: "conversation", title: "Test", messages: messages, run: run)
    }

    private func run(_ status: String, pending: [ChatToolCall] = []) -> ChatRun {
        ChatRun(id: "run", deviceId: "desktop", status: status, pending: pending)
    }
}
