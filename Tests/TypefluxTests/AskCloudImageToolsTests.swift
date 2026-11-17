import Foundation
import Testing
import TypefluxChat
@testable import Typeflux

private actor CloudImageFixture: AskCloudImageTransporting {
    var creates: [(AskCloudImageRequest, String)] = []
    var reads = 0
    var failFirstPoll = true
    var failCreate = false
    var enabled = true
    let id = "0d674b52-4549-4167-bde1-afebc7ce26e2"
    func configure(enabled: Bool = true, failCreate: Bool = false) { self.enabled = enabled; self.failCreate = failCreate }
    func catalog(token _: String) async throws -> AskCloudImageCatalog {
        .init(models: enabled ? [.init(alias: "image:gpt", generate: true, edit: true, aspectRatios: ["1:1", "16:9"], resolutions: ["1K"])] : [],
              defaultGenerateModel: "image:gpt", defaultEditModel: "image:gpt")
    }
    func upload(dataURL _: String, token _: String) async throws -> String { "uploaded-ref" }
    func create(_ request: AskCloudImageRequest, key: String, token _: String) async throws -> AskCloudImageJob {
        creates.append((request, key))
        if failCreate { throw URLError(.networkConnectionLost) }
        return .init(id: id, state: "processing", deadline: Date().addingTimeInterval(600))
    }
    func job(id: String, token _: String) async throws -> AskCloudImageJob {
        reads += 1
        if reads == 1 && failFirstPoll { throw URLError(.timedOut) }
        return .init(id: id, state: "succeeded", imageUrl: "https://example.com/image.png", deadline: Date())
    }
}

private actor CloudImageHTTP: CloudHTTPSession {
    var requests: [URLRequest] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body = #"{"code":"OK","data":{"id":"0d674b52-4549-4167-bde1-afebc7ce26e2","state":"succeeded","image_url":"https://example.com/image.png","deadline":"2026-11-17T09:00:00Z"}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private struct CloudImageProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        .init(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor struct AskCloudImageToolsTests {
    private func host(_ images: CloudImageFixture) -> AskDeviceBuiltinHost {
        .init(transport: AskDeviceTransport(), token: { "account" }, images: images, imagePollWait: {})
    }
    private func conversation() -> AskConversation {
        .init(id: "conversation", title: "Image", revision: 1, updatedAt: Date(), messages: [],
              run: .init(id: "run", deviceId: "device", status: "running", steps: 1, updatedAt: Date(), tools: [], pending: []))
    }
    @Test func catalogControlsBothToolsWithoutLocalAPIKey() async throws {
        let images = CloudImageFixture(), host = host(images)
        #expect(await host.availableDefinitions().map(\.name).contains("image_generate"))
        #expect(await host.availableDefinitions().map(\.name).contains("image_edit"))
        let definitions = await host.availableDefinitions()
        let definition = try #require(definitions.first { $0.name == "image_generate" })
        let encoded = try AskCoding.encoder().encode(definition)
        let schema = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let properties = (schema["parameters"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        #expect(properties?["aspect_ratio"]?["enum"] as? [String] == ["16:9", "1:1"])
        #expect(properties?["resolution"]?["enum"] as? [String] == ["1K"])
        await images.configure(enabled: false)
        #expect(await host.availableDefinitions().map(\.name) == host.definitions().map(\.name))
    }
    @Test func pollingFailureDoesNotResubmitAndReturnsImageCard() async throws {
        let images = CloudImageFixture()
        let output = await host(images).execute(.init(call: .init(id: "call", function: .init(name: "image_generate", arguments: #"{"prompt":"cat"}"#)), conversation: conversation(), budgeted: false))
        #expect(!output.isError && output.generatedImage?.assetId == images.id)
        #expect(await images.creates.count == 1)
        #expect(await images.reads == 2)
        #expect(await images.creates.first?.1.hasPrefix("device-image:") == true)
    }
    @Test func uncertainSubmissionIsNeverAutomaticallyRepeated() async throws {
        let images = CloudImageFixture()
        await images.configure(failCreate: true)
        let output = await host(images).execute(.init(call: .init(id: "call", function: .init(name: "image_generate", arguments: #"{"prompt":"cat"}"#)), conversation: conversation(), budgeted: false))
        #expect(output.isError && output.text.contains("Do not automatically submit"))
        #expect(await images.creates.count == 1)
        #expect(await images.reads == 0)
    }
    @Test func cancellationKeepsJobIdentityAndNeverResubmits() async throws {
        let images = CloudImageFixture()
        let host = AskDeviceBuiltinHost(transport: AskDeviceTransport(), token: { "account" }, images: images,
            imagePollWait: { throw CancellationError() })
        let output = await host.execute(.init(call: .init(id: "call", function: .init(name: "image_generate", arguments: #"{"prompt":"cat"}"#)), conversation: conversation(), budgeted: false))
        #expect(output.isError && output.generatedImage == nil)
        #expect(output.text.contains("job_id=" + images.id))
        #expect(await images.creates.count == 1)
        #expect(await images.reads == 0)
    }
    @Test func editingResolvesUserReferencesAndPreservesGeneratedAssetIDs() async throws {
        let images = CloudImageFixture()
        var c = conversation()
        c.messages = [.init(id: "upload", role: "user", text: "Edit", image: "data:image/png;base64,x", createdAt: Date())]
        let projected = AskLocalPrompt.message(c.messages[0])["content"] as? [[String: Any]]
        #expect((projected?.first?["text"] as? String)?.contains("\"upload\"") == true)
        let call = AskToolCall(id: "edit", function: .init(name: "image_edit", arguments: #"{"prompt":"blue","image_refs":["upload","previous-job"]}"#))
        let output = await host(images).execute(.init(call: call, conversation: c, budgeted: false))
        #expect(!output.isError)
        #expect(await images.creates.first?.0.operation == "edit")
        #expect(await images.creates.first?.0.inputAssetIds == ["uploaded-ref", "previous-job"])
    }
    @Test func transportUsesExistingCreditProtocolAndStableIdempotency() async throws {
        let http = CloudImageHTTP()
        let transport = AskCloudImageTransport(executor: .init(selector: .init(baseURLs: [URL(string: "https://cloud.example")!], prober: CloudImageProber()), session: http))
        let result = try await transport.create(.init(operation: "edit", prompt: "blue", inputAssetIds: ["ref"]), key: "stable", token: "account")
        #expect(result.output?.generatedImage?.url == "https://example.com/image.png")
        let request = try #require(await http.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Typeflux-Credit-Version") == "2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer account")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "stable")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["input_asset_ids"] as? [String] == ["ref"])
    }
    @Test func workEngineOffersCloudImagesAndPersistsApprovedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = CloudImageFixture()
        let engine = AskLocalEngine(directory: root, builtinTools: host(images), allowsCloudModels: true)
        var request = AskSendRequest(id: "message", deviceId: "device", text: "Generate a cat", tools: [], modelRef: "cloud:default")
        request.kind = "work"; request.clientToolApproval = true
        var c = try await engine.send(conversationId: "conversation", request: request, token: "")
        #expect(c.run?.cloudTools?.contains { $0.name == "image_generate" } == true)
        let call = AskToolCall(id: "call", function: .init(name: "image_generate", arguments: #"{"prompt":"cat"}"#))
        c = try await engine.inferenceResult(conversationId: c.id, request: .init(runId: #require(c.run?.id), deviceId: "device", inferenceId: #require(c.run?.inference?.id), content: "", toolCalls: [call], usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2)), token: "")
        #expect(c.run?.status == "waiting_tool")
        #expect(await images.creates.isEmpty)
        c = try await engine.result(conversationId: c.id, request: .init(approveExecution: true, runId: #require(c.run?.id), deviceId: "device", toolCallId: "call", content: "", isError: false), token: "")
        #expect(c.messages.filter { $0.generatedImage != nil }.count == 1)
        #expect(await images.creates.count == 1)
        let reloaded = AskLocalEngine(directory: root, builtinTools: host(images), allowsCloudModels: true)
        let saved = try await reloaded.conversation(id: c.id, token: "")
        #expect(saved.messages.last?.generatedImage == c.messages.last?.generatedImage)
    }
}
