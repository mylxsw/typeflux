import Foundation
import TypefluxChat

/// Cloud inference is one authenticated request. It never creates a server run
/// or submits a result back to a server state machine. Transport loss is not
/// automatically retried against another replica because billing may have begun.
struct AskDeviceModelClient: AskModelCompleting {
    static func authenticated(_ connection: SettingsStore.TextLLMConfiguration, token: String) -> SettingsStore
        .TextLLMConfiguration {
        guard connection.provider == .typefluxCloud else { return connection }
        return .init(provider: connection.provider, baseURL: connection.baseURL, model: connection.model,
                     apiKey: token, apiStyle: connection.apiStyle)
    }

    var custom: any AskModelCompleting = AskCustomInference()
    var executor = CloudRequestExecutor()
    var session: URLSession = .init(configuration: .ephemeral, delegate: AskModelRedirectPolicy(), delegateQueue: nil)

    func complete(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration,
                  payload: String, onUsage: (@Sendable (AskTokenUsage) async -> Void)?,
                  onProgress: (@Sendable (AskStreamProgress) async -> Void)?) async throws -> (String, [AskToolCall]) {
        guard provider.isCloud else {
            return try await custom.complete(
                provider: provider,
                connection: connection,
                payload: payload,
                onUsage: onUsage,
                onProgress: onProgress
            )
        }
        guard !connection.apiKey.isEmpty else { throw AuthError.unauthorized }
        guard var body = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { throw AskStreamError.invalidResponse }
        let deadline = body.removeValue(forKey: "typeflux_deadline") as? Double
        let bounded = body.removeValue(forKey: "typeflux_budget") as? Bool == true
        if bounded, let deadline, deadline <= Date().timeIntervalSince1970 { throw AskBudgetError.reached("duration") }
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        let path = AskDeviceTransport.path + "/completions"
        let endpoint = await executor.primaryEndpoint()
        var request = try ChatRequest.make(baseURL: endpoint, path: path, method: "POST",
                                           body: JSONSerialization.data(withJSONObject: body), token: connection.apiKey,
                                           headers: ["X-Scenario": "ask-anything", "X-Typeflux-Model-Catalog": "1"])
        request.timeoutInterval = bounded ? min(
            180,
            max(0.1, (deadline ?? Date().timeIntervalSince1970 + 180) - Date().timeIntervalSince1970)
        ) : 180
        TypefluxCloudRequestHeaders.applyClientInfo(to: &request)
        return try await AskCustomInference(session: session).stream(request, style: .openAI,
                                                                     onUsage: onUsage,
                                                                     onProgress: { await onProgress?($0) })
    }
}
