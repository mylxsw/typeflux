import Foundation
import Testing
@testable import Typeflux
import TypefluxChat

private actor DeviceMetadataHTTP: CloudHTTPSession {
    var status = 200
    var body = Data()
    var requests: [URLRequest] = []
    func reply(_ value: some Encodable) throws {
        status = 200
        body = try Data(#"{"code":"OK","data":"#.utf8) + (AskCoding.encoder().encode(value)) + Data("}".utf8)
    }

    func raw(_ status: Int, _ value: String) {
        self.status = status; body = Data(value.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct DeviceMetadataProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        .init(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor struct AskDeviceTransportTests {
    private func transport(_ http: DeviceMetadataHTTP) -> AskDeviceTransport {
        .init(executor: CloudRequestExecutor(selector: CloudEndpointSelector(
            baseURLs: [URL(string: "https://device.example")!], prober: DeviceMetadataProber()
        ), session: http))
    }

    private var conversation: AskConversation {
        .init(id: UUID().uuidString.lowercased(), title: "Game", revision: 3, updatedAt: Date(), messages: [],
              run: .init(
                  id: UUID().uuidString.lowercased(),
                  deviceId: UUID().uuidString.lowercased(),
                  status: "waiting_inference",
                  steps: 0,
                  updatedAt: Date(),
                  tools: [AskBuiltinPlan.definition],
                  pending: [],
                  inference: .init(id: "model", payload: "Private model input")
              ))
    }

    @Test func `history snapshots use independent paths and never include execution payloads`() async throws {
        let http = DeviceMetadataHTTP(), api = transport(http)
        var value = conversation
        value.memory = AskMemory(global: "Private pinned memory")
        let snapshot = try AskDeviceSnapshot(
            deviceId: #require(value.run?.deviceId),
            revision: value.revision,
            conversation: value
        )
        #expect(value.run?.inference != nil)
        #expect(snapshot.conversation?.memory == nil)
        #expect(snapshot.conversation?.run?.inference == nil)
        #expect(snapshot.conversation?.run?.tools.isEmpty == true)
        try await http.reply([AskConversationSummary(id: value.id, title: value.title, updatedAt: value.updatedAt)])
        let list = try await api.list(token: "account-token", offset: 50)
        #expect(list.first?.id == value.id)
        let request = try #require(await http.requests.last)
        #expect(request.url?.path == "/api/v1/ask/device/history")
        #expect(request.url?.query == "offset=50")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer account-token")
        try await http.reply(snapshot)
        let restored = try await api.snapshot(id: value.id, token: "account-token")
        #expect(restored?.conversation?.id == value.id)
        try await http.reply(["saved": true])
        try await api.put(id: value.id, snapshot: snapshot, token: "account-token")
        let write = try #require(await http.requests.last)
        #expect(write.httpMethod == "PUT")
        let body = try #require(write.httpBody)
        let decoded = try AskCoding.decoder().decode(AskDeviceSnapshot.self, from: body)
        #expect(decoded.conversation?.run?.inference == nil)
        #expect(!String(decoding: body, as: UTF8.self).contains("Private"))
        try await http.reply(["saved": false])
        await #expect(throws: ChatAPIError.invalidResponse) { try await api.put(
            id: value.id,
            snapshot: snapshot,
            token: "account-token"
        ) }
        await http.raw(404, "Not an envelope")
        let missing = try await api.snapshot(id: value.id, token: "account-token")
        #expect(missing == nil)
        await http.raw(401, "{}")
        await #expect(throws: ChatAPIError.unauthorized) { try await api.snapshot(id: value.id, token: "account-token")
        }
    }

    @Test func `public web calls remain host approved and return errors without dispatching local writes`(
    ) async throws {
        struct WebReply: Encodable { let text: String; let isError: Bool }
        let http = DeviceMetadataHTTP(), transport = transport(http)
        try await http.reply(WebReply(text: "Public page", isError: false))
        let host = AskDeviceBuiltinHost(transport: transport, token: { "account-token" })
        #expect(Set(host.definitions().map(\.name)) == ["update_plan", "web_search", "web_fetch"])
        let read = try #require(host.definitions().first { $0.name == "web_fetch" })
        if case .independentWebRead = host.executionClassification(for: read) {}
        else { Issue.record("Web reads must retain their execution classification") }
        if case .serial = host.executionClassification(for: AskBuiltinPlan.definition) {}
        else { Issue.record("Plans stay serial") }
        let call = AskToolCall(
            id: "read",
            type: "function",
            function: .init(name: "web_fetch", arguments: #"{"url":"https://example.com"}"#)
        )
        let result = await host.execute(.init(call: call, conversation: conversation, budgeted: false))
        #expect(result.text == "Public page" && !result.isError)
        let request = try #require(await http.requests.last)
        #expect(request.url?.path == "/api/v1/ask/device/tools")
        #expect(request.httpMethod == "POST")
        let blocked = AskDeviceBuiltinHost(transport: transport, token: { throw AuthError.unauthorized })
        let error = await blocked.execute(.init(call: call, conversation: conversation, budgeted: false))
        #expect(error.isError)
        #expect(await http.requests.count == 1)
        let planCall = AskToolCall(
            id: "plan",
            type: "function",
            function: .init(name: "update_plan", arguments: #"{"items":[{"step":"Build","status":"in_progress"}]}"#)
        )
        let plan = await host.execute(.init(call: planCall, conversation: conversation, budgeted: false))
        #expect(!plan.isError && plan.plan?.first?.step == "Build")
        #expect(await http.requests.count == 1)
    }
}
