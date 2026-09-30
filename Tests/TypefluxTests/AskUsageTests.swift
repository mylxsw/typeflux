import Foundation
import Testing
@testable import Typeflux

@Suite("Ask usage accounting")
struct AskUsageTests {
    @Test func terminalUsageWithoutChoicesIsRetained() throws {
        var parser = AskProviderStream(style: .openAI)
        try parser.consume(#"{"choices":[{"delta":{"content":"Hello"},"finish_reason":"stop"}]}"#)
        try parser.consume(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":12,"total_tokens":112}}"#)
        try parser.consume("[DONE]")
        #expect(parser.progress.usage == .init(promptTokens: 100, completionTokens: 12, totalTokens: 112))
        #expect(try parser.result().0 == "Hello")
    }

    @Test func providerUsageNormalizesCacheAndReasoningWithoutDoubleCounting() throws {
        var parser = AskProviderStream(style: .anthropic)
        try parser.consume(#"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0,"cache_read_input_tokens":80,"cache_creation_input_tokens":20}}}"#)
        #expect(parser.progress.usage?.promptTokens == 110)
        #expect(parser.progress.usage?.incomplete == true)
        try parser.consume(#"{"type":"message_delta","usage":{"output_tokens":25}}"#)
        #expect(parser.progress.usage?.totalTokens == 135)
        #expect(parser.progress.usage?.incomplete == false)
        let gemini = AskTokenUsage.parse(["usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 30, "thoughtsTokenCount": 70, "totalTokenCount": 200]], style: .gemini)
        #expect(gemini?.completionTokens == 100)
        #expect(gemini?.totalTokens == 200)
        let huge = AskTokenUsage.parse(["usage": ["input_tokens": Int.max, "cache_read_input_tokens": Int.max, "output_tokens": 1]], style: .anthropic)
        #expect(huge == nil)
    }

    @Test func missingAndInvalidUsageIsNotZero() {
        #expect(AskTokenUsage.parse([:], style: .openAI) == nil)
        #expect(AskTokenUsage.parse(["usage": ["prompt_tokens": 1]], style: .openAI) == nil)
        #expect(AskTokenUsage.parse(["usage": ["prompt_tokens": -1, "completion_tokens": 5]], style: .openAI) == nil)
        #expect(AskTokenUsage.parse(["usage": ["prompt_tokens": 5, "completion_tokens": 1, "total_tokens": 2]], style: .openAI) == nil)
        #expect(!AskTokenUsage(promptTokens: 20_000_000, completionTokens: 0, totalTokens: 20_000_000).isValid)
        #expect(AskUsageTotals(calls: 1, pending: 1).creditsText == "—")
        #expect(AskUsageTotals(calls: 1, missing: 1).tokenText(0) == "—")
        #expect(AskUsageTotals(calls: 2, missing: 1).tokenText(12) == "≥12")
        #expect(AskUsageTotals(calls: 1, estimated: 1).tokenText(12) == "≈12")
        #expect(AskUsageTotals(calls: 1, missing: 1, external: 1).creditsText == "0")
        #expect(AskUsageTotals(calls: 1, missing: 1).creditsText == "—")
        #expect(AskUsageTotals(microcredits: 1, calls: 1).creditsText == "<0.01")
        #expect(AskUsageTotals(calls: 1, external: 1).creditsText == "0")
        #expect(AskUsageTotals(calls: 1, external: 1).statusKey == "ask.usage.external")
        #expect(AskUsageTotals(calls: 2, missing: 1).statusKey == "ask.usage.incomplete")
        #expect(AskUsageTotals(calls: 1, pending: 1).statusKey == "ask.usage.pending")
        #expect(AskUsageTotals(microcredits: 1_000_000, calls: 1).creditsText == "1")
        #expect(AskUsageTotals(calls: 1).statusKey == "ask.usage.confirmed")
    }

    @Test func contextReserveAndUnknownCapacity() {
        var context = AskContextUsage(modelRef: "cloud:daily", inputTokens: 31_200, outputReserve: 8192, capacity: 128_000, summarized: false)
        #expect(context.remaining == 88_608)
        #expect(context.fraction == 0.24375)
        #expect(!context.isHigh)
        context.inputTokens = 123_000
        #expect(context.isHigh)
        #expect(context.remaining == 0)
        context.capacity = nil
        #expect(context.fraction == nil)
        #expect(context.remaining == nil)
    }

    @Test func usageOnlyUpdatesSurviveSSEAndCache() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var conversation = AskConversation(id: UUID().uuidString, title: "Test", revision: 10, updatedAt: date, messages: [])
        conversation.usage = .init(version: 1, since: date, historicalGap: false, total: .init(calls: 1, pending: 1), runs: [:])
        var stream = AskConversationStreamState()
        let encode: (AskConversation) throws -> String = { String(decoding: try AskCoding.encoder().encode($0), as: UTF8.self) }
        _ = try stream.consume(event: "snapshot", data: encode(conversation))
        var newer = conversation
        newer.usage?.version = 2
        newer.usage?.total = .init(microcredits: 200_000, calls: 1)
        #expect(try stream.consume(event: "snapshot", data: encode(newer))?.usage?.version == 2)
        #expect(try stream.consume(event: "snapshot", data: encode(conversation)) == nil)
        conversation.revision = 11
        #expect(try stream.consume(event: "snapshot", data: encode(conversation))?.usage?.version == 2)
        var progress = newer
        progress.revision = 11; progress.usage?.version = 3
        #expect(try stream.consume(event: "progress", data: encode(progress))?.usage?.version == 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try AskConversationCache(url: root.appendingPathComponent("test.sqlite"))
        try await cache.save(newer, owner: "owner")
        try await cache.save(conversation, owner: "owner")
        let cached = try await cache.load(id: conversation.id, owner: "owner")
        #expect(cached?.revision == 11)
        #expect(cached?.usage?.version == 2)
        var late = newer; late.usage?.version = 4
        try await cache.save(late, owner: "owner")
        let reconciled = try await cache.load(id: conversation.id, owner: "owner")
        #expect(reconciled?.revision == 11)
        #expect(reconciled?.usage?.version == 4)
        #expect(try stream.consume(event: "snapshot", data: encode(late))?.revision == 11)
        #expect(stream.value?.usage?.version == 4)
        #expect(try await cache.load(id: conversation.id, owner: "other") == nil)
    }

    @Test func optionalFieldsRemainBackwardCompatible() throws {
        let raw = #"{"id":"test","title":"Old","revision":1,"updated_at":"2026-09-30T00:00:00Z","messages":[]}"#
        let c = try AskCoding.decoder().decode(AskConversation.self, from: Data(raw.utf8))
        #expect(c.usage == nil); #expect(c.contextUsage == nil)
    }
}
