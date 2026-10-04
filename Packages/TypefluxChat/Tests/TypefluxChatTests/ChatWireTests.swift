import Foundation
import XCTest
@testable import TypefluxChat

final class ChatWireTests: XCTestCase {
    func testCodecUsesSnakeCaseAndBothISODateFormats() throws {
        struct Sample: Codable { var deviceId: String; var updatedAt: Date }
        for stamp in ["2026-01-02T03:04:05Z", "2026-01-02T03:04:05.123456Z"] {
            let sample = try ChatCoding.decoder().decode(Sample.self, from: Data("{\"device_id\":\"phone\",\"updated_at\":\"\(stamp)\",\"future\":true}".utf8))
            XCTAssertEqual(sample.deviceId, "phone")
            let encoded = try JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(sample)) as! [String: Any]
            XCTAssertEqual(encoded["device_id"] as? String, "phone")
            XCTAssertNotNil(encoded["updated_at"])
        }
        XCTAssertThrowsError(try ChatCoding.decoder().decode(Sample.self, from: Data(#"{"device_id":"phone","updated_at":"bad"}"#.utf8)))
    }

    func testConversationIdentityCanonicalizesDecodeMutationAndEncode() throws {
        let upper = "550E8400-E29B-41D4-A716-446655440000"
        var wrapper = try JSONDecoder().decode(ChatConversationID.self, from: Data("\"\(upper)\"".utf8))
        XCTAssertEqual(wrapper.wrappedValue, upper.lowercased())
        XCTAssertEqual(ChatConversationID.legacy(wrapper.wrappedValue), upper)
        XCTAssertEqual(ChatConversationID.legacy("legacy-id"), "legacy-id")
        wrapper.wrappedValue = "local-id"
        XCTAssertEqual(String(data: try JSONEncoder().encode(wrapper), encoding: .utf8), "\"local-id\"")
        wrapper.wrappedValue = upper
        XCTAssertEqual(wrapper.wrappedValue, upper.lowercased())
    }

    func testSessionDecodesLegacyKeysWithoutLosingRefreshToken() throws {
        for payload in [
            #"{"access_token":"a","expires_at":123,"refresh_token":"r"}"#,
            #"{"accessToken":"a","expiresAt":"123","refreshToken":"r"}"#,
            #"{"accessToken":"a","expiresIn":123.5,"refreshToken":"r"}"#,
            #"{"access_token":"a","expires_in":123,"refresh_token":"r"}"#
        ] {
            let session = try JSONDecoder().decode(ChatSession.self, from: Data(payload.utf8))
            XCTAssertEqual(session, ChatSession(accessToken: "a", expiresAt: 123, refreshToken: "r"))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ChatSession.self, from: Data(#"{"access_token":"a","expires_at":1e100}"#.utf8)))
        let noRefresh = try JSONDecoder().decode(ChatSession.self, from: Data(#"{"access_token":"a","expires_at":0}"#.utf8))
        XCTAssertNil(noRefresh.refreshToken)
        XCTAssertThrowsError(try JSONDecoder().decode(ChatSession.self, from: Data(#"{"expires_at":0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(ChatSession.self, from: Data(#"{"access_token":"a","expires_at":"invalid"}"#.utf8)))
    }

    func testRequestPreservesBasePrefixQueryAndHeaders() throws {
        let request = ChatRequest.make(baseURL: URL(string: "https://example.test/proxy/")!,
            path: "/api/v1/ask/conversations?offset=10", method: "POST", body: Data("{}".utf8), token: "secret",
            timeout: 42, headers: ["X-Scenario": "ask-anything"])
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/proxy/api/v1/ask/conversations?offset=10")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.timeoutInterval, 42)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Scenario"), "ask-anything")
        XCTAssertEqual(ChatRequest.resolve(baseURL: URL(string: "https://example.test")!, path: "api/v1"), URL(string: "https://example.test/api/v1"))
        XCTAssertEqual(ChatRequest.pathComponent("a/b?c"), "a%2Fb%3Fc")
    }

    func testPathComponentsAreEncodedExactlyOnceWithoutInjectingAQueryOrFragment() throws {
        let id = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(ChatRequest.pathComponent(id), id)
        for unsafe in ["a/b?next=1#fragment", "%2F", "中文", ".", ".."] {
            let encoded = ChatRequest.pathComponent(unsafe)
            let request = ChatRequest.make(baseURL: URL(string: "https://example.test/proxy%20prefix/")!,
                                           path: ChatRequest.conversationsPath + "/" + encoded)
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.percentEncodedPath, "/proxy%20prefix/api/v1/ask/conversations/" + encoded)
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(components.host, "example.test")
        }
    }

    func testCatalogPricingRetainsMultiplierAndSupportsLegacyModels() throws {
        let data = Data(#"[{"id":"balanced","name":"Balanced","vision":true,"pricing":{"multiplier":"2.5","base_rate_version":"v1","unit":"credit"}},{"id":"legacy","name":"Legacy"}]"#.utf8)
        let models = try ChatCoding.decoder().decode([ChatModel].self, from: data)
        XCTAssertEqual(models[0].pricing?["multiplier"], "2.5")
        XCTAssertEqual(models[0].pricing?["base_rate_version"], "v1")
        XCTAssertEqual(models[0].pricing?["unit"], "credit")
        XCTAssertNil(models[1].pricing)
    }

    func testEnvelopeDistinguishesUnauthorizedServerAndMalformedResponses() throws {
        let value: Int = try ChatRequest.decode(data: Data(#"{"code":"OK","data":42}"#.utf8), statusCode: 200)
        XCTAssertEqual(value, 42)
        for (status, json, expected) in [
            (401, "not JSON", ChatAPIError.unauthorized),
            (503, #"{"code":"BUSY","message":"retry later"}"#, .server(code: "BUSY", message: "retry later")),
            (200, "{}", .invalidResponse),
            (200, #"{"code":"OK","data":null}"#, .server(code: "OK", message: nil))
        ] {
            XCTAssertThrowsError(try ChatRequest.decode(Int.self, data: Data(json.utf8), statusCode: status)) {
                XCTAssertEqual($0 as? ChatAPIError, expected)
            }
        }
    }

    func testCloudOnlyRequestCannotAdvertiseDesktopTools() throws {
        let request = ChatSendRequest(id: "message", deviceId: "phone", text: "hello", image: "data:image/png;base64,AA==", modelRef: "cloud:one", timeZone: "UTC", locale: "en")
        let body = try JSONSerialization.jsonObject(with: ChatCoding.encoder().encode(request)) as! [String: Any]
        XCTAssertEqual(body["platform"] as? String, "iOS")
        XCTAssertEqual(body["tools"] as? [String], [])
        XCTAssertEqual(body["device_id"] as? String, "phone")
        XCTAssertEqual(body["model_ref"] as? String, "cloud:one")
        XCTAssertEqual(body["image"] as? String, "data:image/png;base64,AA==")
        XCTAssertEqual(body["time_zone"] as? String, "UTC")
    }

    func testDesktopRunAcceptsNullOrMissingPendingAndUnknownMetadata() throws {
        for pending in [",\"pending\":null", "", ",\"pending\":[]"] {
            let json = "{\"id\":\"run\",\"device_id\":\"mac\",\"status\":\"future_status\",\"updated_at\":\"2026-01-02T03:04:05Z\",\"recovery\":{\"version\":2}\(pending)}"
            let run = try ChatCoding.decoder().decode(ChatRun.self, from: Data(json.utf8))
            XCTAssertTrue(run.pending.isEmpty)
            XCTAssertTrue(run.isActive)
            XCTAssertEqual(run.status, "future_status")
        }
    }

    func testPortableDTOInitializersAndDesktopProjection() throws {
        let call = ChatToolCall(id: "call", type: "function", function: .init(name: "search", arguments: "{}"), thoughtSignature: "sig")
        let message = ChatMessage(id: "message", role: "tool", text: "result", toolCalls: [call], toolCallId: "call", isError: false)
        let run = ChatRun(id: "run", deviceId: "mac", status: "waiting_tool", pending: [call])
        let value = ChatConversation(id: "chat", title: "Title", messages: [message], run: run)
        XCTAssertEqual(value.messages[0].toolCalls?.first?.function.name, "search")
        XCTAssertTrue(run.requiresDesktop)
        XCTAssertTrue(run.isActive)
        XCTAssertFalse(ChatRun(id: "r", deviceId: "d", status: "completed").isActive)
        XCTAssertFalse(ChatRun(id: "r", deviceId: "d", status: "running").requiresDesktop)
        XCTAssertEqual(ChatModel(id: "gpt", name: "GPT", vision: true).reference, "cloud:gpt")
        let summary = ChatConversationSummary(id: "chat", title: "Title")
        XCTAssertEqual(try ChatCoding.decoder().decode(ChatConversationSummary.self, from: ChatCoding.encoder().encode(summary)).id, summary.id)
    }
}
