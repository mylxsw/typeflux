import AppKit
import Testing
@testable import Typeflux

@Suite("Ask regenerate", .serialized, .exclusiveUIState)
@MainActor
struct AskRegenerateTests {
    private func answered() async throws -> AskTestFixture {
        let f = try AskTestFixture()
        f.model.draft.text = "Question"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.messages.count == 2 && !f.model.isBusy }
        return f
    }

    @Test func regenerateReplacesTheAnswerInsteadOfAskingAgain() async throws {
        let f = try await answered()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let question = try #require(f.model.selected?.messages.first)
        let answer = try #require(f.model.selected?.messages.last)
        #expect(f.model.canRegenerate(answer))

        f.model.regenerate(answer.id)
        try await f.wait { f.model.selected?.messages.last?.id != answer.id && !f.model.isBusy }

        // The question stays, the answer is replaced, nothing is appended.
        #expect(f.model.selected?.messages.count == 2)
        #expect(f.model.selected?.messages.first?.id == question.id)
        #expect(f.model.selected?.messages.last?.text == "This is another answer.")
        let sent = await f.api.regenerations
        #expect(sent.count == 1)
        #expect(sent.first?.messageId == answer.id)
        #expect(sent.first?.deviceId == "device")
        #expect(sent.first?.tools?.isEmpty == false)
        // Regenerating must not send another message.
        let sends = await f.api.sends
        #expect(sends.count == 1)
    }

    @Test func onlyTheLatestCompleteAnswerCanBeRegenerated() async throws {
        let f = try await answered()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let question = try #require(f.model.selected?.messages.first)
        let first = try #require(f.model.selected?.messages.last)

        // A user turn is never a regenerate target.
        #expect(!f.model.canRegenerate(question))
        // An empty assistant turn has nothing to replace.
        #expect(!f.model.canRegenerate(AskMessage(id: "empty", role: "assistant", text: "", createdAt: Date())))

        f.model.draft.text = "Follow-up"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.messages.count == 4 && !f.model.isBusy }
        let latest = try #require(f.model.selected?.messages.last)
        #expect(!f.model.canRegenerate(first))
        #expect(f.model.canRegenerate(latest))
    }

    @Test func regenerateNeedsTheMessageToBelongToTheSelectedConversation() async throws {
        let f = try AskTestFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let stranger = AskMessage(id: "stranger", role: "assistant", text: "Answer", createdAt: Date())
        // Nothing is selected yet.
        #expect(!f.model.canRegenerate(stranger))

        f.model.draft.text = "Question"
        f.model.submitDraft()
        try await f.wait { f.model.selected?.messages.count == 2 && !f.model.isBusy }
        // Selected now, but this message is not the conversation's latest answer.
        #expect(!f.model.canRegenerate(stranger))
        #expect(f.model.canRegenerate(try #require(f.model.selected?.messages.last)))
    }

    @Test func regenerateSurfacesFailuresWithoutLosingTheAnswer() async throws {
        let f = try await answered()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let answer = try #require(f.model.selected?.messages.last)
        await f.api.setFailRegenerate(true)

        f.model.regenerate(answer.id)
        try await f.wait { !f.model.isBusy && f.model.error != nil }
        #expect(f.model.error != nil)
        // The failed attempt must not remove the answer that is still on screen.
        #expect(f.model.selected?.messages.last?.id == answer.id)
        #expect(f.model.selected?.messages.count == 2)
    }

    @Test func regenerateRequestEncodesSnakeCaseWireKeys() throws {
        let request = AskRegenerateRequest(messageId: "m", deviceId: "d", modelRef: "cloud:fast", tools: [])
        let data = try AskCoding.encoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"message_id\""))
        #expect(json.contains("\"device_id\""))
        #expect(json.contains("\"model_ref\""))
        #expect(!json.contains("\"messageId\""))
    }
}
