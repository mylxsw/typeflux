import Foundation
import Testing
@testable import Typeflux

@Suite("Ask independent model selection", .serialized)
@MainActor
struct AskModelSelectionTests {
    @Test(arguments: ["failed", "cancelled"])
    func retryUsesSelectedVisionModelAndKeepsScreenshot(status: String) async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let models: [AskCloudModel] = [
            .init(id: "text", name: "Text", vision: false),
            .init(id: "vision", name: "Vision", vision: true)
        ]
        await f.api.setCloudModels(models)
        await f.model.modelLibrary.refresh(api: f.api, token: "token")
        let screenshot = "data:image/jpeg;base64,YQ=="
        let value = AskConversation(id: "retry", title: "Screen", revision: 1, updatedAt: Date(), messages: [
            .init(id: "tool-result", role: "tool", text: "Screen", image: screenshot, toolCallId: "capture", createdAt: Date())
        ], run: .init(id: "run", deviceId: "device", status: status, steps: 1, updatedAt: Date(), tools: [], pending: [], modelRef: "cloud:text"), modelRef: "cloud:text")
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(f.model.error != nil)
        #expect(await f.api.retryModels.isEmpty)
        #expect(f.model.selected?.run?.status == status)

        f.model.draft.modelRef = "cloud:vision"
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.retryModels == ["cloud:vision"])
        #expect(f.model.error == nil)
        #expect(f.model.selected?.run?.status == "completed")
        #expect(f.model.selected?.modelRef == "cloud:vision")
        #expect(f.model.selected?.messages == value.messages)
        #expect(f.tools.executions == 0)
        #expect(f.capture.calls == 0)
    }

    @Test func retryWithoutSelectionKeepsConversationModel() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        let value = AskConversation(id: "retry", title: "Task", revision: 1, updatedAt: Date(), messages: [],
            run: .init(id: "run", deviceId: "device", status: "failed", steps: 0, updatedAt: Date(), tools: [], pending: []), modelRef: "cloud:default")
        await f.api.seed(value)
        await f.model.select(value.id)
        f.model.resume()
        try await f.wait { f.model.busyIds.isEmpty }
        #expect(await f.api.retryModels == ["cloud:default"])
        #expect(f.model.selected?.run?.status == "completed")
    }

    @Test func defaultsStayIndependentAndExistingChatsKeepTheirModel() async throws {
        let suite = "ask-models-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let settings = SettingsStore(defaults: defaults)
        settings.llmProvider = .ollama
        let fixture = try AskTestFixture(modelLibrary: library)
        await fixture.model.prepareLauncher()
        library.defaultReference = "cloud:default"
        fixture.model.launcherDraft.text = "First question"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selected?.modelRef == "cloud:default")
        library.defaultReference = "cloud:new-default"
        #expect(fixture.model.modelReference(launcher: false) == "cloud:default")
        #expect(fixture.model.modelReference(launcher: true) == "cloud:new-default")
        #expect(settings.llmProvider == .ollama)
        #expect(settings.effectiveLLMProvider == .ollama)
        library.rewriteReference = "cloud:default"
        #expect(settings.effectiveLLMProvider == .openAICompatible)
        #expect(settings.textLLMConfiguration().provider == .typefluxCloud)
        #expect(library.defaultReference == "cloud:new-default")
        library.rewriteReference = ""
        #expect(settings.effectiveLLMProvider == .ollama)
        fixture.model.newConversation()
        #expect(fixture.model.modelReference(launcher: false) == "cloud:new-default")
        #expect(AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false).defaultReference == "cloud:new-default")
        fixture.model.resetSession()
    }

    @Test func unavailableModelRestoresEditableDraftWithoutSending() async throws {
        let fixture = try AskTestFixture()
        await fixture.model.prepareLauncher()
        fixture.model.launcherDraft.text = "Keep my question"
        fixture.model.launcherDraft.modelRef = "cloud:removed"
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.draft.text == "Keep my question")
        #expect(fixture.model.canSend)
        fixture.model.draft.modelRef = "cloud:default"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.count == 1)
        fixture.model.resetSession()
    }

    @Test func catalogFailuresRemainVisibleAndRetryRestoresChoices() async throws {
        let suite = "ask-catalog-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let api = AskTestAPI()
        await library.refresh(api: api, token: nil)
        #expect(library.catalogError == nil)
        await api.setFailModels(true)
        await library.refresh(api: api, token: "fixture")
        #expect(library.catalogError != nil)
        #expect(library.name(for: "cloud:default") == "Typeflux Cloud")
        await api.setFailModels(false)
        await library.refresh(api: api, token: "fixture")
        #expect(library.catalogError == nil)
        #expect(library.cloud.count == 1)
    }

    @Test func connectionTestCallsTheSelectedModelAndRedirectsAreRejected() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AskModelURLProtocol.self]
        let session = URLSession(configuration: config)
        let adapter = AskCustomInference(session: session)
        try await adapter.test(profile: AskModelProfile(name: "Test", baseURL: "https://example.invalid/v1", model: "m"), key: "fixture")
        var acceptedRedirect = true
        let original = URL(string: "https://example.invalid/v1")!
        let redirect = URLRequest(url: URL(string: "https://another.invalid/")!)
        AskModelRedirectPolicy().urlSession(session, task: session.dataTask(with: original),
            willPerformHTTPRedirection: HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: redirect) { acceptedRedirect = $0 != nil }
        #expect(!acceptedRedirect)
        await #expect(throws: (any Error).self) {
            try await adapter.complete(profile: AskModelProfile(name: "Test", baseURL: "https://example.invalid/v1", model: "m"), key: "", payload: "[]")
        }
    }

    @Test func oldRecordsDecodeAndDraftSelectionSurvivesPersistence() throws {
        let legacy = Data(#"{"text":"Question","include_screenshot":false}"#.utf8)
        var draft = try AskCoding.decoder().decode(AskDraft.self, from: legacy)
        #expect(draft.modelRef == nil)
        draft.modelRef = "custom:" + UUID().uuidString
        let restored = try AskCoding.decoder().decode(AskDraft.self, from: AskCoding.encoder().encode(draft))
        #expect(restored.modelRef == draft.modelRef)
        #expect(restored.request(deviceId: "device", tools: []).modelRef == draft.modelRef)
        let inference = AskInference(id: "request", payload: #"{"tool_call_id":"exact_key","image_url":{"url":"data:..."}}"#)
        let decoded = try AskCoding.decoder().decode(AskInference.self, from: AskCoding.encoder().encode(inference))
        #expect(decoded.payload == inference.payload)
    }

    @Test func invalidEndpointsAreRejectedAndMissingProfilesNeverFallback() throws {
        for endpoint in ["http://example.com", "https://name:password@example.com", "https://example.com?key=secret", "file:///tmp/model", ""] {
            #expect(throws: (any Error).self) { try AskModelProfile(name: "A", baseURL: endpoint, model: "m").validate() }
        }
        for endpoint in ["https://example.com/v1", "http://localhost:11434/v1", "http://127.0.0.1:8000"] {
            try AskModelProfile(name: "A", baseURL: endpoint, model: "m").validate()
        }
        let suite = "ask-models-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        library.rewriteReference = "custom:missing"
        #expect(settings.textLLMConfiguration().baseURL.isEmpty)
        #expect(!settings.isLLMConfigured)
        #expect(library.name(for: "custom:missing") == L("ask.models.unavailable"))
    }

    @Test func customTransportPublishesTextBeforeFinalToolResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskModelURLProtocol.self]
        let recorder = AskStreamRecorder()
        let adapter = AskCustomInference(session: URLSession(configuration: configuration))
        let result = try await adapter.complete(profile: .init(name: "Fixture", baseURL: "https://example.invalid/v1", model: "fixture"), key: "fixture", payload: #"{"messages":[]}"#) { progress in
            await recorder.append(progress)
        }
        let updates = await recorder.updates
        #expect(updates.first?.text == "Ans")
        #expect(updates.last?.text == "Answer")
        #expect(updates.first?.toolCalls.isEmpty == true)
        #expect(result.1.first?.function.arguments == #"{"page_size":5}"#)
    }

    @Test func resumedDeviceInferencePostsResultAndKeepsConversationModel() async throws {
        let suite = "ask-bridge-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = AskModelProfile(name: "Custom", baseURL: "https://example.invalid/v1", model: "chosen-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let fixture = try AskTestFixture(modelLibrary: library)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskModelURLProtocol.self]
        fixture.model.customInference = AskCustomInference(session: URLSession(configuration: configuration))
        let inference = AskInference(id: UUID().uuidString, payload: #"{"messages":[{"role":"user","content":"Hi"}]}"#)
        let conversation = AskConversation(id: "custom-conversation", title: "Custom", revision: 1, updatedAt: Date(), messages: [], run: .init(id: "run", deviceId: "device", status: "waiting_inference", steps: 0, updatedAt: Date(), tools: [], pending: [], modelRef: profile.reference, inference: inference), modelRef: profile.reference)
        await fixture.api.seed(conversation)
        await fixture.model.select(conversation.id)
        fixture.model.resume()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selected?.run?.status == "completed")
        let receipts = await fixture.api.inferenceResults
        #expect(receipts.count == 1)
        #expect(receipts.first?.inferenceId == inference.id)
        #expect(receipts.first?.content == "Answer")
        #expect(fixture.model.modelReference(launcher: false) == profile.reference)
        #expect(await fixture.api.sends.isEmpty)
        fixture.model.resetSession()
    }

    @Test func modelFailuresNeverBecomeSuccessfulAnswers() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AskModelURLProtocol.self]
        let adapter = AskCustomInference(session: URLSession(configuration: config))
        let profile = AskModelProfile(name: "API", baseURL: "https://example.invalid/v1", model: "m")
        for status in [401, 429, 500] {
            AskModelURLProtocol.status = status
            await #expect(throws: (any Error).self) {
                try await adapter.complete(profile: profile, key: "key", payload: #"{"messages":[]}"#)
            }
        }
        AskModelURLProtocol.status = 200
        AskModelURLProtocol.body = #"{"choices":[]}"#
        defer { AskModelURLProtocol.body = nil }
        await #expect(throws: (any Error).self) {
            try await adapter.complete(profile: profile, key: "key", payload: #"{"messages":[]}"#)
        }
    }

    @Test func customAdapterPreservesImagesAndToolsAndUsesOnlySelectedCredentials() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AskModelURLProtocol.self]
        let adapter = AskCustomInference(session: URLSession(configuration: configuration))
        let profile = AskModelProfile(name: "My model", baseURL: "https://example.invalid/v1", model: "chosen-model")
        let payload = #"{"model":"default","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,YQ=="}}]}],"tools":[{"type":"function","function":{"name":"browser","parameters":{"type":"object"}}}]}"#
        let (text, tools) = try await adapter.complete(profile: profile, key: "fixture-key", payload: payload)
        #expect(text == "Answer")
        #expect(tools.first?.function.name == "browser")
        #expect(tools.first?.function.arguments == #"{"page_size":5}"#)
        let request = try #require(AskModelURLProtocol.request)
        #expect(request.url?.absoluteString == "https://example.invalid/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            body = data
        }
        let bodyData = try #require(body)
        let sent = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(sent["model"] as? String == "chosen-model")
        #expect(sent["stream"] as? Bool == false)
        #expect(String(data: bodyData, encoding: .utf8)?.contains("image_url") == true)
        #expect(sent["tools"] != nil)
        #expect(!String(data: bodyData, encoding: .utf8)!.contains("fixture-key"))
    }
}

private final class AskModelURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var requestData = request.httpBody
        if requestData == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                collected.append(contentsOf: bytes.prefix(count))
            }
            requestData = collected
        }
        if let data = requestData,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["stream"] as? Bool == true,
           Self.body == nil {
            let chunks = [
                #"data: {"choices":[{"delta":{"content":"Ans"}}]}"#,
                #"data: {"choices":[{"delta":{"content":"wer","tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"browser","arguments":"{\"page_size\":5}"}}]},"finish_reason":"tool_calls"}]}"#,
                "data: [DONE]"
            ]
            for chunk in chunks { client?.urlProtocol(self, didLoad: Data((chunk + "\n\n").utf8)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data((Self.body ?? #"{"choices":[{"message":{"content":"Answer","tool_calls":[{"id":"call-1","type":"function","function":{"name":"browser","arguments":"{\"page_size\":5}"}}]}}]}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor AskStreamRecorder {
    var updates: [AskStreamProgress] = []
    func append(_ value: AskStreamProgress) { updates.append(value) }
}
