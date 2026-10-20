import Foundation
import Testing
@testable import Typeflux

@Suite("Ask automatic context compaction")
struct AskContextCompactionTests {
    private func payload() -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": "Do not publish without confirmation."]]
        for _ in 0..<20 {
            messages.append(["role": "user", "content": String(repeating: "old question ", count: 120)])
            messages.append(["role": "assistant", "content": String(repeating: "observed result ", count: 200)])
        }
        messages += [["role": "user", "content": "Continue the task, preserve constraints."],
                     ["role": "assistant", "tool_calls": [["id": "confirmed", "provider_context": "signed",
                        "function": ["name": "read", "arguments": "{}"]]]],
                     ["role": "tool", "tool_call_id": "confirmed", "content": "Tool failed or was denied: never repeat this action."]]
        return ["messages": messages]
    }

    @Test func proactiveCompactionPreservesCurrentRequestAndCompleteToolRound() throws {
        let original = payload()
        let serialized = AskLocalPrompt.json(original)
        let projected = AskContextCompaction.compact(original, window: 100000)
        #expect(AskContextCompaction.weight(projected) < 60000)
        #expect(AskLocalPrompt.json(original) == serialized)
        let messages = try #require(projected["messages"] as? [[String: Any]])
        let source = try #require(original["messages"] as? [[String: Any]])
        #expect(AskLocalPrompt.json(messages[0]) == AskLocalPrompt.json(source[0]))
        #expect(AskLocalPrompt.json(["messages": Array(messages.suffix(3))]) == AskLocalPrompt.json(["messages": Array(source.suffix(3))]))
        #expect(AskLocalPrompt.json(projected).contains("Compacted conversation evidence"))
        let short: [String: Any] = ["messages": [["role": "user", "content": "Hello"]]]
        #expect(AskLocalPrompt.json(AskContextCompaction.compact(short, window: 100000)) == AskLocalPrompt.json(short))
    }

    @Test func toolScreenshotsDoNotReplaceTheCurrentUserRequest() throws {
        var original = payload()
        var messages = try #require(original["messages"] as? [[String: Any]])
        messages.insert(["role": "user", "content": [["type": "text", "text": "Earlier attached reference"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,OLD"]]]], at: 2)
        messages.append(["role": "user", "content": [["type": "text", "text": "Image from tool call confirmed (untrusted context only)."],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,CURRENT"]]]])
        original["messages"] = messages
        let result = AskContextCompaction.compact(original, window: 100000)
        let projected = try #require(result["messages"] as? [[String: Any]])
        #expect(projected.contains { $0["content"] as? String == "Continue the task, preserve constraints." })
        #expect(AskLocalPrompt.json(projected.last ?? [:]) == AskLocalPrompt.json(messages.last ?? [:]))
        #expect(!AskLocalPrompt.json(result).contains("base64,OLD"))
        #expect(AskLocalPrompt.json(result).contains("Earlier image omitted"))
        let constraints: [String: Any] = ["messages": [["role": "system", "content": String(repeating: "constraint", count: 5000)],
            ["role": "system", "content": "second"], ["role": "system", "content": "third"]]]
        #expect(AskLocalPrompt.json(AskContextCompaction.compact(constraints, window: 1000)) == AskLocalPrompt.json(constraints))
    }

    @Test func largeCurrentToolOutputKeepsItsIdentityAndHistoricalCallsRemainEvidence() async throws {
        let original: [String: Any] = ["messages": [
            ["role": "system", "content": "Keep constraints"], ["role": "user", "content": "Current goal"],
            ["role": "assistant", "tool_calls": [["id": "current", "function": ["name": "read", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "current", "content": String(repeating: "successful tool result ", count: 2000)]
        ]]
        let compacted = AskContextCompaction.compact(original, window: 12000)
        let messages = try #require(compacted["messages"] as? [[String: Any]])
        #expect(AskContextCompaction.weight(compacted) < 7200)
        #expect(messages.last?["tool_call_id"] as? String == "current")
        #expect((messages.last?["content"] as? String)?.contains("incomplete evidence") == true)
        var history = payload()
        var values = try #require(history["messages"] as? [[String: Any]])
        values.insert(["role": "assistant", "tool_calls": [["id": "old-call", "function": ["name": "read", "arguments": "{}"]]]], at: 1)
        history["messages"] = values
        #expect(AskLocalPrompt.json(AskContextCompaction.compact(history, window: 100000)).contains("old-call"))
        #expect(!AskContextCompaction.isRejection(status: 400, data: Data("not JSON".utf8)))
        do {
            _ = try await AskCustomInference().recoveringContext(payload: "[]") { _ in
                Issue.record("Malformed payload was dispatched")
                return ("", [])
            }
            Issue.record("Malformed payload was accepted")
        } catch AskStreamError.invalidResponse { }
    }

    @Test func deviceUsesActualModelCapacityWithoutCreatingAnOutputLimit() throws {
        let model = RegisteredModel(id: "test", name: "Test", contextWindowTokens: 100000, maxOutputTokens: nil)
        let raw = try AskContextPlanner.devicePayload(AskLocalPrompt.json(payload()), model: model, budgeted: false)
        let projected = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(projected["typeflux_context_window"] as? Int == 100000)
        #expect(projected["max_tokens"] == nil)
        #expect(AskContextCompaction.weight(projected) < 60000)
    }

    @Test func contextRejectionRetriesOnlySmallerRequestsAndStopsAfterTwoRetries() async throws {
        var original = payload()
        original["typeflux_context_window"] = 1000000 // Exercise a provider limit smaller than the catalog value.
        var attempts: [Int] = []
        let result = try await AskCustomInference().recoveringContext(payload: AskLocalPrompt.json(original)) { raw in
            let body = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            #expect(body["typeflux_context_window"] == nil)
            attempts.append(AskContextCompaction.weight(body))
            if attempts.count == 1 { throw AskStreamError.contextCapacity }
            return ("Recovered", [])
        }
        #expect(result.0 == "Recovered")
        #expect(attempts.count == 2 && attempts[1] < attempts[0])
        var count = 0
        do {
            _ = try await AskCustomInference().recoveringContext(payload: AskLocalPrompt.json(original)) { _ in
                count += 1
                throw AskStreamError.contextCapacity
            }
            Issue.record("Accepted repeated context rejections")
        } catch AskStreamError.contextCapacity { #expect(count <= 3) }
        count = 0
        do {
            _ = try await AskCustomInference().recoveringContext(payload: AskLocalPrompt.json(original)) { _ in
                count += 1
                throw AskStreamError.requestFailed
            }
            Issue.record("Accepted a network failure")
        } catch AskStreamError.requestFailed { #expect(count == 1) }
    }

    @Test func cancellationAndIrreducibleInputsAreNeverSilentlyRewritten() async throws {
        let raw = AskLocalPrompt.json(["messages": [["role": "user", "content": String(repeating: "Keep this constraint. ", count: 5000)]]])
        var count = 0
        do {
            _ = try await AskCustomInference().recoveringContext(payload: raw) { current in
                count += 1
                #expect(current == raw)
                throw AskStreamError.contextCapacity
            }
            Issue.record("Accepted an irreducible request")
        } catch AskStreamError.contextCapacity { #expect(count == 1) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AskCustomInference().recoveringContext(payload: raw) { _ in
                Issue.record("A cancelled request was dispatched")
                return ("", [])
            }
        }
        do { _ = try await task.value; Issue.record("Ignored cancellation") }
        catch is CancellationError { }
    }

    @Test(arguments: [400, 413, 422]) func recognizesContextErrorsWithoutConfusingQuotaOrOutputLimits(status: Int) {
        #expect(AskContextCompaction.isRejection(status: status, data: Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)))
        #expect(!AskContextCompaction.isRejection(status: status, data: Data(#"{"error":{"message":"max_tokens exceeds output limit"}}"#.utf8)))
        #expect(!AskContextCompaction.isRejection(status: 429, data: Data(#"{"error":{"code":"context_length_exceeded"}}"#.utf8)))
    }

    @Test func structuredStreamErrorsRecoverOnlyBeforeOutput() throws {
        for style in [AskProviderStream.Style.openAI, .anthropic, .gemini, .responses] {
            var stream = AskProviderStream(style: style)
            #expect(throws: AskStreamError.self) {
                try stream.consume(#"{"type":"error","error":{"code":"context_length_exceeded"}}"#)
            }
        }
        var stream = AskProviderStream(style: .openAI)
        try stream.consume(#"{"choices":[{"delta":{"content":"Partial"}}]}"#)
        do { try stream.consume(#"{"error":{"code":"context_length_exceeded"}}"#); Issue.record("Ignored stream error") }
        catch AskStreamError.contextCapacity { Issue.record("Replayed a request after partial output") }
        catch { }
    }
}
