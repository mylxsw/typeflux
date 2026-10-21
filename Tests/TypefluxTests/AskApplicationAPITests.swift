import Foundation
import Testing
@testable import Typeflux

private enum BoundaryFailure: Error, Equatable { case backend, callback }

private struct BoundaryCall: Equatable, Sendable {
    var method: String
    var arguments: [String: String]
}

private actor BoundaryRecorder {
    var calls: [BoundaryCall] = []
    var failure: BoundaryFailure?
    func fail(_ value: BoundaryFailure?) { failure = value }
    func record(_ method: String, _ arguments: [String: String]) throws {
        calls.append(.init(method: method, arguments: arguments))
        if let failure { throw failure }
        try Task.checkCancellation()
    }
}

private func boundaryValue(_ id: String) -> AskConversation {
    .init(id: id, title: id, revision: 7, updatedAt: Date(timeIntervalSince1970: 42), messages: [])
}

private func boundaryJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = AskCoding.encoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Deliberately has no history or model-administration conformance.
private struct BoundaryRuntime: AskAgentRuntime {
    let recorder: BoundaryRecorder
    var name = "runtime"
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation {
        try await recorder.record("send", ["id": conversationId, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation {
        try await recorder.record("result", ["id": conversationId, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func inferenceResult(conversationId: String, request: AskInferenceResult, token: String) async throws -> AskConversation {
        try await recorder.record("inference", ["id": conversationId, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await recorder.record("cancel", ["id": conversationId, "run": runId, "token": token])
        return boundaryValue(name)
    }
    func cancel(conversationId: String, runId: String, partial: AskInferenceResult?, token: String) async throws -> AskConversation {
        try await recorder.record("cancelPartial", ["id": conversationId, "run": runId, "partial": boundaryJSON(partial), "token": token])
        return boundaryValue(name)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await recorder.record("retry", ["id": conversationId, "run": runId, "device": deviceId, "model": modelRef ?? "nil", "token": token])
        return boundaryValue(name)
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, maxSteps: Int?, token: String) async throws -> AskConversation {
        try await recorder.record("retryLimited", ["id": conversationId, "run": runId, "device": deviceId, "model": modelRef ?? "nil", "limit": maxSteps.map(String.init) ?? "nil", "token": token])
        return boundaryValue(name)
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation {
        try await recorder.record("regenerate", ["id": conversationId, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func steer(conversationId: String, request: AskSteerRequest, token: String) async throws -> AskConversation {
        try await recorder.record("steer", ["id": conversationId, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func resume(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await recorder.record("resume", ["id": conversationId, "run": runId, "token": token])
        return boundaryValue(name)
    }
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        try await recorder.record("observe", ["id": id, "token": token])
        try await onValue(boundaryValue(name))
        // A long-lived subscription must remain owned and cancellable by its caller.
        try await Task.sleep(for: .seconds(3600))
    }
}

private struct BoundaryHistory: AskConversationAccess {
    let recorder: BoundaryRecorder
    var name = "history"
    func conversation(id: String, token: String) async throws -> AskConversation {
        try await recorder.record("conversation", ["id": id, "token": token])
        return boundaryValue(name)
    }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] {
        try await recorder.record("list", ["token": token, "offset": String(offset)])
        return [.init(id: name, title: name, updatedAt: Date(timeIntervalSince1970: 42))]
    }
    func updateTitle(id: String, request: AskTitleRequest, token: String) async throws -> AskConversation {
        try await recorder.record("title", ["id": id, "request": boundaryJSON(request), "token": token])
        return boundaryValue(name)
    }
    func delete(conversationId: String, token: String) async throws {
        try await recorder.record("delete", ["id": conversationId, "token": token])
    }
    func keep(conversationId: String, token: String) async throws -> AskConversation {
        try await recorder.record("keep", ["id": conversationId, "token": token])
        return boundaryValue(name)
    }
    func purgeMemory(token: String) async throws { try await recorder.record("purge", ["token": token]) }
    func purgeMemory(owner: String, token: String) async throws {
        try await recorder.record("purgeOwner", ["owner": owner, "token": token])
    }
}

private struct BoundaryModels: AskModelAccess {
    let recorder: BoundaryRecorder
    var name = "catalog"
    func featureModels(feature: String, token: String) async throws -> [AskCloudModel]? {
        try await recorder.record("feature", ["feature": feature, "token": token])
        return [.init(id: name, name: name)]
    }
    func models(token: String) async throws -> [AskCloudModel] {
        try await recorder.record("models", ["token": token])
        return [.init(id: name, name: name)]
    }
    func models(token: String, scenario: String) async throws -> [AskCloudModel] {
        try await recorder.record("scenario", ["token": token, "scenario": scenario])
        return [.init(id: name, name: name)]
    }
    func usage(id: String, runId: String?, cursor: Int64?, token: String) async throws -> AskUsagePage {
        try await recorder.record("usage", ["id": id, "run": runId ?? "nil", "cursor": cursor.map(String.init) ?? "nil", "token": token])
        return .init(items: [], nextCursor: 91)
    }
}

@Suite(.exclusiveUIState) @MainActor
struct AskApplicationAPITests {
    private let send = AskSendRequest(id: "message", deviceId: "device", text: "question", tools: [])
    private let inference = AskInferenceResult(runId: "run", deviceId: "device", inferenceId: "inference", content: "partial answer")

    @Test func forwardsEveryRuntimeOverloadAndArgument() async throws {
        let runtime = BoundaryRecorder(), history = BoundaryRecorder(), catalog = BoundaryRecorder()
        let api: any AskAPI = AskApplicationAPI(runtime: BoundaryRuntime(recorder: runtime),
                                              conversations: BoundaryHistory(recorder: history), modelAccess: BoundaryModels(recorder: catalog))
        try await exerciseRuntime(api, token: "account", expected: "runtime")
        #expect(await history.calls.isEmpty)
        #expect(await catalog.calls.isEmpty)
        #expect(try await runtime.calls == expectedRuntimeCalls(token: "account"))
        // Dispatch through the narrow existential also reaches the injected implementations.
        let narrow: any AskAgentRuntime = BoundaryRuntime(recorder: runtime)
        #expect(try await narrow.resume(conversationId: "c", runId: "r", token: "t").id == "runtime")
        await #expect(throws: BoundaryFailure.callback) {
            try await narrow.observe(id: "c", token: "t") { _ in throw BoundaryFailure.callback }
        }
    }

    private func exerciseRuntime(_ api: any AskAgentRuntime, token: String, expected: String) async throws {
        let result = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "tool", content: "receipt", isError: true)
        let regenerate = AskRegenerateRequest(maxSteps: 3, messageId: "message", deviceId: "device", modelRef: "model")
        #expect(try await api.send(conversationId: "conversation", request: send, token: token).id == expected)
        #expect(try await api.result(conversationId: "conversation", request: result, token: token).id == expected)
        #expect(try await api.inferenceResult(conversationId: "conversation", request: inference, token: token).id == expected)
        #expect(try await api.cancel(conversationId: "conversation", runId: "run", token: token).id == expected)
        for partial in [nil, inference] {
            #expect(try await api.cancel(conversationId: "conversation", runId: "run", partial: partial, token: token).id == expected)
        }
        #expect(try await api.retry(conversationId: "conversation", runId: "run", deviceId: "device", modelRef: "model", token: token).id == expected)
        for limit in [nil, 0, 17] as [Int?] {
            #expect(try await api.retry(conversationId: "conversation", runId: "run", deviceId: "device", modelRef: nil, maxSteps: limit, token: token).id == expected)
        }
        #expect(try await api.regenerate(conversationId: "conversation", request: regenerate, token: token).id == expected)
        #expect(try await api.steer(conversationId: "conversation", request: .init(runId: "run", message: send), token: token).id == expected)
        #expect(try await api.resume(conversationId: "conversation", runId: "run", token: token).id == expected)
        await #expect(throws: BoundaryFailure.callback) {
            try await api.observe(id: "conversation", token: token) { value in
                #expect(value.id == expected)
                throw BoundaryFailure.callback
            }
        }
    }

    private func expectedRuntimeCalls(token: String) throws -> [BoundaryCall] {
        let result = AskToolResultRequest(runId: "run", deviceId: "device", toolCallId: "tool", content: "receipt", isError: true)
        let regenerate = AskRegenerateRequest(maxSteps: 3, messageId: "message", deviceId: "device", modelRef: "model")
        func request(_ name: String, _ json: String) -> BoundaryCall {
            .init(method: name, arguments: ["id": "conversation", "request": json, "token": token])
        }
        return try [
            request("send", boundaryJSON(send)), request("result", boundaryJSON(result)), request("inference", boundaryJSON(inference)),
            .init(method: "cancel", arguments: ["id": "conversation", "run": "run", "token": token]),
            .init(method: "cancelPartial", arguments: ["id": "conversation", "run": "run", "partial": "null", "token": token]),
            .init(method: "cancelPartial", arguments: ["id": "conversation", "run": "run", "partial": boundaryJSON(inference), "token": token]),
            .init(method: "retry", arguments: ["id": "conversation", "run": "run", "device": "device", "model": "model", "token": token])
        ] + ["nil", "0", "17"].map {
            .init(method: "retryLimited", arguments: ["id": "conversation", "run": "run", "device": "device", "model": "nil", "limit": $0, "token": token])
        } + [request("regenerate", boundaryJSON(regenerate)), request("steer", boundaryJSON(AskSteerRequest(runId: "run", message: send))),
             .init(method: "resume", arguments: ["id": "conversation", "run": "run", "token": token]),
             .init(method: "observe", arguments: ["id": "conversation", "token": token])]
    }

    @Test func historyAndCatalogRemainIndependentOfRuntimeFailure() async throws {
        let runtime = BoundaryRecorder(), history = BoundaryRecorder(), catalog = BoundaryRecorder()
        await runtime.fail(.backend)
        let api: any AskAPI = AskApplicationAPI(runtime: BoundaryRuntime(recorder: runtime),
                                              conversations: BoundaryHistory(recorder: history), modelAccess: BoundaryModels(recorder: catalog))
        #expect(try await api.conversation(id: "c", token: "t").id == "history")
        #expect(try await api.list(token: "t", offset: 27).map(\.id) == ["history"])
        let title = AskTitleRequest(action: "rename", title: "New title")
        #expect(try await api.updateTitle(id: "c", request: title, token: "t").id == "history")
        #expect(try await api.keep(conversationId: "c", token: "t").id == "history")
        try await api.delete(conversationId: "c", token: "t")
        try await api.purgeMemory(token: "t")
        try await api.purgeMemory(owner: "owner", token: "t")
        #expect(try await api.models(token: "t").map(\.id) == ["catalog"])
        #expect(try await api.models(token: "t", scenario: "rewrite").map(\.id) == ["catalog"])
        #expect(try await api.featureModels(feature: "translate", token: "t")?.map(\.id) == ["catalog"])
        #expect(try await api.usage(id: "c", runId: "r", cursor: 83, token: "t").nextCursor == 91)
        #expect(await runtime.calls.isEmpty)
        #expect(try await history.calls == [
            .init(method: "conversation", arguments: ["id": "c", "token": "t"]),
            .init(method: "list", arguments: ["offset": "27", "token": "t"]),
            .init(method: "title", arguments: ["id": "c", "request": boundaryJSON(title), "token": "t"]),
            .init(method: "keep", arguments: ["id": "c", "token": "t"]),
            .init(method: "delete", arguments: ["id": "c", "token": "t"]),
            .init(method: "purge", arguments: ["token": "t"]),
            .init(method: "purgeOwner", arguments: ["owner": "owner", "token": "t"])
        ])
        #expect(await catalog.calls == [
            .init(method: "models", arguments: ["token": "t"]),
            .init(method: "scenario", arguments: ["token": "t", "scenario": "rewrite"]),
            .init(method: "feature", arguments: ["token": "t", "feature": "translate"]),
            .init(method: "usage", arguments: ["id": "c", "run": "r", "cursor": "83", "token": "t"])
        ])
        await #expect(throws: BoundaryFailure.backend) { try await api.send(conversationId: "c", request: send, token: "t") }
        await history.fail(.backend)
        await #expect(throws: BoundaryFailure.backend) { try await api.delete(conversationId: "c", token: "t") }
        await catalog.fail(.backend)
        await #expect(throws: BoundaryFailure.backend) { try await api.models(token: "t") }
    }

    @Test func subscriptionAndTaskCancellationPropagate() async throws {
        let recorder = BoundaryRecorder()
        let api = AskApplicationAPI(runtime: BoundaryRuntime(recorder: recorder),
                                    conversations: BoundaryHistory(recorder: BoundaryRecorder()), modelAccess: BoundaryModels(recorder: BoundaryRecorder()))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await api.observe(id: "c", token: "t") { _ in continuation.yield(()) }
        }
        for await _ in stream { break }
        continuation.finish()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await api.send(conversationId: "c", request: send, token: "t")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test func defaultCompositionPreservesBothRoutesAndPurgeOwnership() async throws {
        let cloud = BoundaryRecorder(), local = BoundaryRecorder()
        func backend(_ recorder: BoundaryRecorder, _ name: String) -> AskApplicationAPI {
            .init(runtime: BoundaryRuntime(recorder: recorder, name: name), conversations: BoundaryHistory(recorder: recorder, name: name),
                  modelAccess: BoundaryModels(recorder: recorder, name: name))
        }
        let api = AskApplicationAPI.routed(cloud: backend(cloud, "cloud"), local: backend(local, "local"))
        for (token, name) in [("", "local"), ("account", "cloud")] {
            try await exerciseRuntime(api, token: token, expected: name)
            #expect(try await api.conversation(id: "c", token: token).id == name)
            #expect(try await api.list(token: token, offset: 2).first?.id == name)
            #expect(try await api.models(token: token).first?.id == name)
            #expect(try await api.featureModels(feature: "ask", token: token)?.first?.id == name)
            #expect(try await api.keep(conversationId: "c", token: token).id == name)
        }
        try await api.purgeMemory(token: "")
        try await api.purgeMemory(token: "account")
        try await api.purgeMemory(owner: "owner", token: "account")
        #expect(await local.calls.filter { $0.method == "purge" }.count == 2)
        #expect(await local.calls.last == .init(method: "purgeOwner", arguments: ["owner": "owner", "token": ""]))
        #expect(await cloud.calls.filter { $0.method == "purge" }.count == 2)
        #expect(await cloud.calls.last == .init(method: "purge", arguments: ["token": "account"]))
    }
}

/// Uses exactly the required legacy surface, inheriting all pre-extraction defaults.
private struct BoundaryLegacyAPI: AskAPI {
    let recorder: BoundaryRecorder
    func conversation(id: String, token: String) async throws -> AskConversation {
        try await recorder.record("conversation", ["id": id, "token": token])
        return boundaryValue("legacy")
    }
    func list(token: String, offset: Int) async throws -> [AskConversationSummary] { [] }
    func send(conversationId: String, request: AskSendRequest, token: String) async throws -> AskConversation { boundaryValue("legacy") }
    func result(conversationId: String, request: AskToolResultRequest, token: String) async throws -> AskConversation { boundaryValue("legacy") }
    func cancel(conversationId: String, runId: String, token: String) async throws -> AskConversation {
        try await recorder.record("cancel", ["id": conversationId, "run": runId, "token": token])
        return boundaryValue("legacy")
    }
    func retry(conversationId: String, runId: String, deviceId: String, modelRef: String?, token: String) async throws -> AskConversation {
        try await recorder.record("retry", ["id": conversationId, "run": runId, "device": deviceId, "model": modelRef ?? "nil", "token": token])
        return boundaryValue("legacy")
    }
    func regenerate(conversationId: String, request: AskRegenerateRequest, token: String) async throws -> AskConversation { boundaryValue("legacy") }
    func delete(conversationId: String, token: String) async throws {}
}

extension AskApplicationAPITests {
    @Test func legacyFakeRetainsAllDefaultsThroughNarrowExistentials() async throws {
        let recorder = BoundaryRecorder()
        let fake = BoundaryLegacyAPI(recorder: recorder)
        let runtime: any AskAgentRuntime = fake
        let history: any AskConversationAccess = fake
        let models: any AskModelAccess = fake
        #expect(try await runtime.retry(conversationId: "c", runId: "r", deviceId: "d", modelRef: "m", maxSteps: 11, token: "t").id == "legacy")
        #expect(try await runtime.cancel(conversationId: "c", runId: "r", partial: inference, token: "t").id == "legacy")
        #expect(try await runtime.resume(conversationId: "c", runId: "r", token: "t").id == "legacy")
        await #expect(throws: BoundaryFailure.callback) {
            try await runtime.observe(id: "c", token: "t") { value in
                #expect(value.id == "legacy")
                throw BoundaryFailure.callback
            }
        }
        #expect(await recorder.calls == [
            .init(method: "retry", arguments: ["id": "c", "run": "r", "device": "d", "model": "m", "token": "t"]),
            .init(method: "cancel", arguments: ["id": "c", "run": "r", "token": "t"]),
            .init(method: "conversation", arguments: ["id": "c", "token": "t"]),
            .init(method: "conversation", arguments: ["id": "c", "token": "t"])
        ])
        #expect(try await models.featureModels(feature: "ask", token: "t") == nil)
        #expect(try await models.models(token: "t").map(\.id) == ["default"])
        #expect(try await models.models(token: "t", scenario: "rewrite").map(\.id) == ["default"])
        try await history.purgeMemory(token: "t")
        try await history.purgeMemory(owner: "owner", token: "t")
        await #expect(throws: AskLocalError.self) {
            try await history.updateTitle(id: "c", request: .init(action: "rename"), token: "t")
        }
        await #expect(throws: AskLocalError.self) {
            try await runtime.inferenceResult(conversationId: "c", request: inference, token: "t")
        }
        await #expect(throws: AskLocalError.self) {
            try await runtime.steer(conversationId: "c", request: .init(runId: "r", message: send), token: "t")
        }
        await #expect(throws: AskLocalError.self) {
            try await models.usage(id: "c", runId: nil, cursor: nil, token: "t")
        }
        await #expect(throws: AskLocalError.self) {
            try await history.keep(conversationId: "c", token: "t")
        }
    }

    @Test func legacyObservationSleepAndHistoryErrorsPropagateThroughFacade() async throws {
        let recorder = BoundaryRecorder()
        let fake = BoundaryLegacyAPI(recorder: recorder)
        let api: any AskAPI = AskApplicationAPI(runtime: fake, conversations: fake, modelAccess: fake)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await api.observe(id: "c", token: "t") { _ in continuation.yield(()) }
        }
        for await _ in stream { break }
        continuation.finish()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await api.observe(id: "c", token: "t") { _ in Issue.record("A cancelled poll must not publish") }
        }
        try await cancelled.value
        #expect(await recorder.calls.count == 1)
        await recorder.fail(.backend)
        await #expect(throws: BoundaryFailure.backend) { try await api.resume(conversationId: "c", runId: "r", token: "t") }
        await #expect(throws: BoundaryFailure.backend) { try await api.observe(id: "c", token: "t") { _ in Issue.record("Failed read must not publish") } }
    }
}
