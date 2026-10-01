import AppKit
import SwiftUI
import Testing
@testable import Typeflux

@Suite("Ask stream decoding")
struct AskStreamTests {
    @Test func rejectsOversizedFramesInvalidUTF8AndTooManyCalls() throws {
        var bytes = AskSSEFrame(limit: 2)
        _ = try bytes.push(65); _ = try bytes.push(66)
        #expect(throws: (any Error).self) { try bytes.push(67) }
        var invalidUTF8 = AskSSEFrame()
        _ = try invalidUTF8.push(255)
        #expect(throws: (any Error).self) { try invalidUTF8.push(10) }
        var stream = AskProviderStream(style: .openAI)
        for index in 0..<8 {
            try stream.consume("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":\(index),\"id\":\"call-\(index)\",\"function\":{\"name\":\"screen\",\"arguments\":\"{}\"}}]}}]}")
        }
        #expect(throws: (any Error).self) { try stream.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":8}]}}]}"#) }
        var state = AskConversationStreamState()
        #expect(try state.consume(event: "unknown", data: "{}") == nil)
        #expect(throws: (any Error).self) { try state.consume(event: "unavailable", data: "{}") }
    }

    @Test func nativeBlockStartsAndEmptyToolInputAreHandled() throws {
        var stream = AskProviderStream(style: .anthropic)
        try stream.consume(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"Plan"}}"#)
        try stream.consume(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Answer"}}"#)
        try stream.consume(#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"one","name":"screen","input":{}}}"#)
        try stream.consume(#"{"type":"content_block_stop","index":2}"#)
        try stream.consume(#"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"two","name":"browser","input":{"action":"read"}}}"#)
        try stream.consume(#"{"type":"message_stop"}"#)
        #expect(try stream.result().1.first?.function.arguments == "{}")
        #expect(stream.progress.reasoning == "Plan")
        #expect(throws: (any Error).self) { try stream.consume(#"{"type":"error"}"#) }
    }
    @Test func `byte decoder preserves blank frames and split unicode`() throws {
        var decoder = AskSSEFrame()
        let wire = "event: progress\r\ndata: 你好\r\n\r\n: heartbeat\n\ndata: next\n\n"
        var frames: [String] = []
        for byte in wire.utf8 {
            if let (_, data) = try decoder.push(byte) {
                frames.append(data)
            }
        }
        #expect(frames == ["你好", "next"])
    }

    @Test func `sse preserves multiline data and ignores comments`() throws {
        var frame = AskSSEFrame()
        #expect(try frame.append(": heartbeat") == nil)
        #expect(try frame.append("event: progress") == nil)
        #expect(try frame.append("data: first") == nil)
        #expect(try frame.append("data: second") == nil)
        let completed = try frame.append("")
        let result = try #require(completed)
        #expect(result.0 == "progress")
        #expect(result.1 == "first\nsecond")
        #expect(frame.event == "message")
        var small = AskSSEFrame(limit: 4)
        #expect(throws: (any Error).self) { try small.append("data: long") }
    }

    @Test func `open AI reassembles interleaved tools and reasoning before completion`() throws {
        var stream = AskProviderStream(style: .openAI)
        try stream.consume(#"{"choices":[{"delta":{"reasoning_content":"Compare options"}}]}"#)
        #expect(stream.progress.reasoning == "Compare options")
        try stream
            .consume(
                #"{"choices":[{"delta":{"content":"Hello ","tool_calls":[{"index":0,"id":"a","function":{"name":"browser","arguments":"{\"q\":"}},{"index":1,"id":"b","function":{"name":"screen","arguments":"{}"}}]}}]}"#
            )
        #expect(stream.progress.text == "Hello ")
        #expect(stream.progress.toolCalls.count == 2)
        #expect(throws: (any Error).self) { try stream.result() }
        try stream
            .consume(
                #"{"choices":[{"delta":{"content":"世界","tool_calls":[{"index":0,"function":{"arguments":"\"hello\"}"}}]},"finish_reason":"tool_calls"}]}"#
            )
        let result = try stream.result()
        #expect(result.0 == "Hello 世界")
        #expect(result.1.map(\.id) == ["a", "b"])
        #expect(result.1.first?.function.arguments == #"{"q":"hello"}"#)
    }

    @Test func `rejects incomplete and invalid tool streams`() throws {
        var stream = AskProviderStream(style: .openAI)
        try stream.consume(#"{"choices":[{"delta":{"content":"partial"}}]}"#)
        #expect(throws: (any Error).self) { try stream.result() }
        #expect(throws: (any Error).self) { try stream.consume(#"{"error":{"message":"no"}}"#) }
        #expect(throws: (any Error).self) {
            try stream.consume(#"{"choices":[{"delta":{"tool_calls":[{"index":-1}]}}]}"#)
        }
        try stream
            .consume(
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"bad","function":{"name":"tool","arguments":"{"}}]}}]}"#
            )
        try stream.consume("[DONE]")
        #expect(throws: (any Error).self) { try stream.result() }
    }

    @Test func `anthropic consumes thinking text and tool JSON`() throws {
        var stream = AskProviderStream(style: .anthropic)
        try stream
            .consume(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan"}}"#)
        try stream.consume(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}"#)
        try stream
            .consume(
                #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tool-1","name":"screen","input":{}}}"#
            )
        try stream
            .consume(
                #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#
            )
        try stream.consume(#"{"type":"message_stop"}"#)
        let result = try stream.result()
        #expect(result.0 == "Answer")
        #expect(stream.progress.reasoning == "Plan")
        #expect(result.1.first?.id == "tool-1")
    }

    @Test func `gemini keeps thought signatures separate from visible thoughts`() throws {
        var stream = AskProviderStream(style: .gemini)
        try stream.consume(#"{"candidates":[{"content":{"parts":[{"text":"Plan","thought":true},{"text":"Hello"}]}}]}"#)
        try stream
            .consume(
                #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"screen","args":{}},"thoughtSignature":"opaque"}]},"finishReason":"STOP"}]}"#
            )
        let result = try stream.result()
        #expect(result.0 == "Hello")
        #expect(stream.progress.reasoning == "Plan")
        #expect(result.1.first?.thoughtSignature == "opaque")
    }

    @Test func `progress ignores stale revisions and keeps history`() throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let value = AskConversation(id: id, title: "Fixture", revision: 3, updatedAt: Date(), messages: [])
        var state = AskConversationStreamState()
        let snapshot = try String(decoding: AskCoding.encoder().encode(value), as: UTF8.self)
        #expect(try state.consume(event: "snapshot", data: snapshot)?.revision == 3)
        #expect(try state.consume(event: "snapshot", data: snapshot) == nil)
        let progress = "{\"id\":\"\(id)\",\"revision\":4,\"updated_at\":\"2026-09-29T00:00:00Z\",\"run\":null}"
        #expect(try state.consume(event: "progress", data: progress)?.revision == 4)
        #expect(try state.consume(event: "progress", data: progress) == nil)
    }
}

@Suite("Ask selectable transcript", .serialized)
@MainActor struct AskTranscriptTextTests {
    @Test func `native mouse drag selects across paragraphs`() async throws {
        guard ProcessInfo.processInfo.environment["TYPEFLUX_ASK_SNAPSHOTS"] != nil else { return }
        _ = NSApplication.shared
        let view =
            NSHostingView(rootView: AskTranscriptText(text: "First paragraph\n\nSecond paragraph\n\nThird paragraph"))
        let window = AskTestVoiceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> AskTranscriptText.Editor? {
            if let editor = view as? AskTranscriptText.Editor {
                return editor
            }
            return view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(view))
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        layout.ensureLayout(for: container)
        func location(_ index: Int) -> NSPoint {
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return editor.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil)
        }
        func event(_ type: NSEvent.EventType, at index: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: location(index),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }
        try NSApp.postEvent(event(.leftMouseDragged, at: 26), atStart: false)
        try NSApp.postEvent(event(.leftMouseUp, at: 26), atStart: false)
        try editor.mouseDown(with: event(.leftMouseDown, at: 2))
        #expect(editor.selectedRange().length >= 20)
        #expect((editor.string as NSString).substring(with: editor.selectedRange()).contains("\n"))
    }

    @Test func `selection spans paragraphs and code and survives updates`() {
        let editor = AskTranscriptText.Editor()
        editor.setContent(
            "First paragraph\n\nSecond paragraph\n\n```swift\nlet x = 1\n```",
            markdown: true,
            dark: false
        )
        #expect(editor.string.contains("First paragraph\nSecond paragraph\nlet x = 1"))
        let selection = NSRange(location: 3, length: 25)
        editor.setSelectedRange(selection)
        let content = editor.string
        editor.setContent(
            "First paragraph\n\nSecond paragraph\n\n```swift\nlet x = 1\n```\n\nMore output",
            markdown: true,
            dark: false
        )
        #expect(editor.selectedRange() == selection)
        #expect((editor.string as NSString).substring(with: selection) == (content as NSString)
            .substring(with: selection))
        editor.setContent(
            "First paragraph\n\nSecond paragraph\n\n```swift\nlet x = 1\n```\n\nMore output",
            markdown: true,
            dark: false
        )
        #expect(editor.selectedRange() == selection)
    }

    @Test func `table columns and quotes remain separate`() {
        let value = AskMarkdownText
            .render("| Option | Cost |\n| --- | --- |\n| A | Low |\n\n> Quoted text\n\n~~Removed~~")
        #expect(value.string.contains("Option\nCost\nA\nLow"))
        #expect(value.string.contains("Quoted text"))
        let range = (value.string as NSString).range(of: "Removed")
        #expect(value.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil)
    }

    @Test func `lists emphasis and unsafe links remain readable`() {
        let value = AskMarkdownText.render("# Title\n\n1. **One**\n2. *Two*\n\n[Link](javascript:alert)\n\n`code`")
        #expect(value.string.contains("1. One"))
        #expect(value.string.contains("2. Two"))
        let range = (value.string as NSString).range(of: "Link")
        #expect(value.attribute(.link, at: range.location, effectiveRange: nil) == nil)
    }
}
