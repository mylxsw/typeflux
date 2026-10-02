import Foundation
import Testing
@testable import Typeflux

@Suite("Ask streamed tool compatibility")
struct AskStreamToolCompatibilityTests {
    private func frame(index: Int = 1, id: String = "screen-call", name: String = "computer",
                       arguments: String) throws -> String {
        let part: [String: Any] = ["index": index, "id": id, "type": "function",
                                   "function": ["name": name, "arguments": arguments]]
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["tool_calls": [part]]]]])
        return String(decoding: data, as: UTF8.self)
    }

    @Test func `mini max repeated metadata and placeholder`() throws {
        var stream = AskProviderStream(style: .openAI)
        try stream.consume(#"{"choices":[{"delta":{"content":"Checking the screen."}}]}"#)
        for fragment in ["{}", "{", #""action": "s"#, "creenshot", "\"", "}"] {
            try stream.consume(frame(arguments: fragment))
        }
        #expect(throws: (any Error).self) { try stream.result() }
        try stream.consume(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)
        try stream.consume(#"{"choices":[],"usage":{"prompt_tokens":2134,"completion_tokens":36,"total_tokens":2170}}"#)
        try stream.consume("[DONE]")
        let (text, calls) = try stream.result()
        #expect(text == "Checking the screen.")
        #expect(calls.count == 1)
        #expect(calls.first?.id == "screen-call")
        #expect(calls.first?.function.name == "computer")
        #expect(calls.first?.function.arguments == #"{"action": "screenshot"}"#)
        #expect(try stream.result().1 == calls)
    }

    @Test func `preserves valid empty and standard arguments`() throws {
        let cases: [([String], String)] = [
            (["{}"], "{}"),
            (["{}", "", " "], "{} "),
            (["{", "}"], "{}"),
            (["", "{", #""action":"screenshot""#, "}"], #"{"action":"screenshot"}"#),
            ([" \n{}\t", "", #" {"action":"screenshot"} "#], #" {"action":"screenshot"} "#),
            (["{}", #"{"payload":{"value":"{}"}}"#], #"{"payload":{"value":"{}"}}"#)
        ]
        for (fragments, expected) in cases {
            var stream = AskProviderStream(style: .openAI)
            for fragment in fragments {
                try stream.consume(frame(arguments: fragment))
            }
            try stream.consume("[DONE]")
            let calls = try stream.result().1
            #expect(calls.first?.function.name == "computer")
            #expect(calls.first?.function.arguments == expected)
        }
    }

    @Test func `rejects malformed replacement arguments`() throws {
        for fragments in [
            ["{}", "{"], ["{}", "{bad}"], ["{}", "[]"], ["{}", "null"],
            ["{}", #"{"a":1}"#, #"{"b":2}"#], ["{}{}"],
            ["{", "}", #"{"a":1}"#], [#"{"a":1}"#, #"{"b":2}"#]
        ] {
            var stream = AskProviderStream(style: .openAI)
            for fragment in fragments {
                try stream.consume(frame(arguments: fragment))
            }
            try stream.consume("[DONE]")
            #expect(throws: (any Error).self) { try stream.result() }
        }
    }

    @Test func `interleaved calls keep separate name and argument state`() throws {
        var stream = AskProviderStream(style: .openAI)
        try stream.consume(frame(arguments: "{}"))
        try stream.consume(frame(index: 0, id: "browser-call", name: "brow", arguments: "{"))
        try stream.consume(frame(arguments: #"{"action":"screenshot"}"#))
        // Omit ID on standard continuation frames, including a repeated name fragment.
        try stream
            .consume(
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"ser","arguments":"\"action\":\"read\"}"}}]}}]}"#
            )
        try stream.consume(frame(index: 2, id: "repeat-fragment", name: "a", arguments: "{"))
        try stream
            .consume(#"{"choices":[{"delta":{"tool_calls":[{"index":2,"function":{"name":"a","arguments":"}"}}]}}]}"#)
        try stream.consume("[DONE]")
        let calls = try stream.result().1
        #expect(calls.map(\.function.name) == ["browser", "computer", "aa"])
        #expect(calls.map(\.function.arguments) == [#"{"action":"read"}"#, #"{"action":"screenshot"}"#, "{}"])
    }

    @Test func `placeholder does not bypass limits or missing identity`() throws {
        var oversized = AskProviderStream(style: .openAI)
        try oversized.consume(frame(arguments: "{}"))
        #expect(throws: (any Error).self) {
            try oversized.consume(frame(arguments: "{\"x\":\"" + String(repeating: "x", count: 64000) + "\"}"))
        }
        var missing = AskProviderStream(style: .openAI)
        try missing
            .consume(
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"computer","arguments":"{}"}}]}}]}"#
            )
        try missing
            .consume(
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"action\":\"screenshot\"}"}}]}}]}"#
            )
        try missing.consume("[DONE]")
        #expect(throws: (any Error).self) { try missing.result() }
    }
}
