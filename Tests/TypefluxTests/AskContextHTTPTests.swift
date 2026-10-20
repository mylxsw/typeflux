import Foundation
import XCTest
@testable import Typeflux

final class AskContextHTTPTests: XCTestCase {
    func testAllDeviceProviderTransportsRecoverFromContextRejection() async throws {
        for style in [LLMRemoteAPIStyle.openAICompatible, .anthropic, .gemini, .responses] {
            for streaming in [false, true] {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [ContextRejectionProtocol.self]
                let session = URLSession(configuration: config)
                defer { session.invalidateAndCancel() }
                ContextRejectionProtocol.reset(style: style, streaming: streaming)
                var messages: [[String: Any]] = [["role": "system", "content": "Keep constraints."]]
                for _ in 0..<12 {
                    messages += [["role": "user", "content": String(repeating: "history ", count: 100)],
                                 ["role": "assistant", "content": String(repeating: "answer ", count: 100)]]
                }
                messages.append(["role": "user", "content": "Continue"])
                let payload = AskLocalPrompt.json(["messages": messages, "typeflux_context_window": 1000000])
                let connection = SettingsStore.TextLLMConfiguration(provider: .custom, baseURL: "https://example.invalid/v1",
                    model: "synthetic", apiKey: "synthetic", apiStyle: style)
                let progress: (@Sendable (AskStreamProgress) async -> Void)? = streaming ? { _ in } : nil
                let result = try await AskCustomInference(session: session).complete(
                    provider: .init(id: "synthetic", name: "Synthetic", apiStyle: style), connection: connection,
                    payload: payload, onProgress: progress)
                XCTAssertEqual(result.0, "OK", "\(style) stream=\(streaming)")
                let bodies = ContextRejectionProtocol.captured()
                XCTAssertEqual(bodies.count, 2)
                XCTAssertLessThan(bodies[1].count, bodies[0].count)
                for body in bodies {
                    XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("typeflux_context_window"))
                }
            }
        }
    }
}

private final class ContextRejectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var style = LLMRemoteAPIStyle.openAICompatible
    nonisolated(unsafe) private static var streaming = false

    static func reset(style: LLMRemoteAPIStyle, streaming: Bool) {
        lock.withLock { bodies = []; self.style = style; self.streaming = streaming }
    }
    static func captured() -> [Data] { lock.withLock { bodies } }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let (attempt, style, streaming) = Self.lock.withLock {
            Self.bodies.append(data)
            return (Self.bodies.count, Self.style, Self.streaming)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: attempt == 1 ? 400 : 200, httpVersion: nil,
            headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = attempt == 1 ? #"{"error":{"code":"context_length_exceeded","message":"prompt is too long"}}"# : Self.reply(style, streaming: streaming)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func reply(_ style: LLMRemoteAPIStyle, streaming: Bool) -> String {
        if streaming {
            switch style {
            case .anthropic:
                return [#"{"type":"message_start","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":0}}}"#,
                        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"OK"}}"#,
                        #"{"type":"content_block_stop","index":0}"#,
                        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}"#,
                        #"{"type":"message_stop"}"#].map { "data: \($0)\n\n" }.joined()
            case .gemini: return "data: " + #"{"candidates":[{"content":{"parts":[{"text":"OK"}]},"finishReason":"STOP"}]}"# + "\n\n"
            case .responses:
                return "data: " + #"{"type":"response.output_text.delta","delta":"OK"}"# + "\n\ndata: " +
                    #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}}"# + "\n\n"
            default: return "data: " + #"{"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
            }
        }
        switch style {
        case .anthropic: return #"{"content":[{"type":"text","text":"OK"}]}"#
        case .gemini: return #"{"candidates":[{"content":{"parts":[{"text":"OK"}]}}]}"#
        case .responses: return #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#
        default: return #"{"choices":[{"message":{"content":"OK"}}]}"#
        }
    }
}
