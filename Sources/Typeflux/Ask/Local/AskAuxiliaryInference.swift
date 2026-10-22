import Foundation

/// Captures one helper invocation independently from visible answer progress.
private actor AskAuxiliaryCapture {
    var usage: AskTokenUsage?
    var progress = AskStreamProgress()
    func observe(_ value: AskTokenUsage) { usage = value }
    func observe(_ value: AskStreamProgress) { progress = value }
    func receipt(_ inference: AskInference, run: String, device: String, text: String,
                 calls: [AskToolCall], failed: Bool) -> AskInferenceResult {
        .init(runId: run, deviceId: device, inferenceId: inference.id, content: text,
              toolCalls: calls, usage: usage, failed: failed,
              finishReason: progress.truncated ? "length" : nil)
    }
}

enum AskAuxiliaryInference {
    @MainActor static func complete(_ inference: AskInference, run: String, device: String,
                                    library: AskModelLibrary, client: any AskModelCompleting = AskCustomInference(), cloudToken: String? = nil) async -> AskInferenceResult {
        let capture = AskAuxiliaryCapture()
        do {
            guard let body = try JSONSerialization.jsonObject(with: Data(inference.payload.utf8)) as? [String: Any],
                  let reference = body["model"] as? String,
                  let (provider, model) = library.registry.resolve(reference), !provider.isCloud || cloudToken?.isEmpty == false else {
                throw AskStreamError.invalidResponse
            }
            let payload = try AskContextPlanner.devicePayload(inference.payload, model: model, budgeted: false)
            let connection = AskDeviceModelClient.authenticated(library.connection(provider, model: model), token: cloudToken ?? "")
            let (text, calls) = try await client.complete(provider: provider,
                connection: connection, payload: payload,
                onUsage: { await capture.observe($0) }, onProgress: { await capture.observe($0) })
            return await capture.receipt(inference, run: run, device: device, text: text, calls: calls, failed: false)
        } catch {
            return await capture.receipt(inference, run: run, device: device, text: "", calls: [], failed: true)
        }
    }
}
