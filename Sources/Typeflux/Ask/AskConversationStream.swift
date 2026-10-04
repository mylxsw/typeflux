import Foundation

struct AskConversationStreamState {
    private(set) var value: AskConversation?
    struct Progress: Decodable {
        var id: String
        var revision: Int64
        var updatedAt: Date
        var run: AskRun?
        var usage: AskConversationUsage?
        var contextUsage: AskContextUsage?
    }

    mutating func consume(event: String, data: String) throws -> AskConversation? {
        let bytes = Data(data.utf8)
        if event == "snapshot" {
            let next = try AskCoding.decoder().decode(AskConversation.self, from: bytes)
            if let value, value.id == next.id, !next.isNewer(than: value) {
                return nil
            }
            let merged = value?.reconciling(next) ?? next
            value = merged
            return merged
        }
        if event == "progress", var next = value {
            let progress = try AskCoding.decoder().decode(Progress.self, from: bytes)
            guard progress.id == next.id else { return nil }
            var incoming = next
            incoming.revision = progress.revision; incoming.updatedAt = progress.updatedAt
            incoming.run = progress.run; incoming.usage = progress.usage
            incoming.contextUsage = progress.contextUsage ?? next.contextUsage
            guard incoming.isNewer(than: next) else { return nil }
            next = next.reconciling(incoming, preservingEqualRevisionContent: true)
            value = next
            return next
        }

        if event == "unavailable" {
            throw AskStreamError.requestFailed
        }
        return nil
    }
}

extension AskAPIClient {
    func observe(id: String, token: String, onValue: @Sendable (AskConversation) async throws -> Void) async throws {
        let base = await executor.primaryEndpoint()
        var request = URLRequest(url: AuthEndpointResolver.resolve(
            baseURL: base,
            path: "/api/v1/ask/conversations/\(id)/events"
        ))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("ask-anything", forHTTPHeaderField: "X-Scenario")
        TypefluxCloudRequestHeaders.applyClientInfo(to: &request)
        if recoveryMetadataEnabled {
            request.setValue("run_recovery_v1", forHTTPHeaderField: "X-Typeflux-Capabilities")
        }
        request.timeoutInterval = 40
        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
            throw AskStreamError.requestFailed
        }
        var frame = AskSSEFrame(limit: 32_000_000)
        var state = AskConversationStreamState()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let (event, data) = try frame.push(byte), let value = try state.consume(event: event, data: data) {
                try await onValue(value)
            }
        }
    }
}
