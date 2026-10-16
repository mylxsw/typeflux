import Foundation
import TypefluxMediaProtocol

/// Storage and presentation never grant authority or fetch a resource URI.
enum AskTypedContent {
    static let maxBytes = 1_000_000
    static let maxBlocks = 64
    static let maxTextBytes = 60000
    static let advertisement = AskHarnessContract(version: 1, capabilities: [AskHarnessCapability.typedContent.rawValue])
    // Immutable receipt parser, shared across the batch just like its native authority.
    typealias ImageReader = @Sendable (JSONValue) -> (data: Data, type: MediaImageType)?

    struct Projection {
        var text: String
        var images: [String]
        var incomplete: Bool
    }

    static func json(_ object: [String: Any]) -> JSONValue {
        JSONValue(data: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
    static func object(_ value: JSONValue) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: value.data)) as? [String: Any] ?? [:]
    }
    static func clip(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        return String(decoding: value.utf8.prefix(bytes), as: UTF8.self).replacingOccurrences(of: "\u{fffd}", with: "")
    }

    static func output(from result: MCPToolsCallResult,
                       normalize: (@Sendable (Data, MediaImageType) async throws -> String)? = nil,
                       normalizer: AskToolImageNormalizer = .shared,
                       readImage: ImageReader = { imageInput(object($0)) }) async -> AskLocalToolOutput {
        let batch = normalizer.batch(using: normalize)
        var blocks = result.content.map(\.raw)
        if let value = result.structuredContent { blocks.append(json(["type": "structured_content", "value": object(value)])) }
        if let value = result.metadata { blocks.append(json(["type": "mcp_metadata", "value": object(value)])) }
        var outcome = await prepare(.init(status: result.isError == true ? "unknown" : "ok", content: blocks),
                                    limit: 4, batch: batch, readImage: readImage)
        if !batch.isCurrent { withholdImages(&outcome) }
        let projection = project(outcome)
        let legacyImage = projection.images.first
        // A legacy peer must never interpret a partial multi-image result as complete.
        let incomplete = projection.incomplete || projection.images.count > 1
        var text = projection.text
        if projection.images.count > 1 { text += "\n[Multiple images retained; legacy delivery is incomplete]" }
        return AskLocalToolOutput(content: text, image: legacyImage, isError: result.isError == true || incomplete, outcome: outcome)
    }

    static func withoutPreparedImages(_ output: AskLocalToolOutput) -> AskLocalToolOutput {
        var copy = output
        copy.image = nil
        if copy.outcome == nil { copy.outcome = .init(status: output.isError ? "unknown" : "ok") }
        copy.outcome?.preparedImages = [:]
        copy.outcome?.projectionWithheld = true
        copy.content += "\n[Image projection withheld after cancellation or permission change; execution result retained]"
        copy.isError = true
        return copy
    }

    static func bounded(_ original: AskExecutionOutcome) -> AskExecutionOutcome {
        guard original.content != nil else { return original }
        var result = original
        var total = 0
        var blocks: [JSONValue] = []
        for (index, raw) in (original.content ?? []).enumerated() {
            if index >= maxBlocks - 1 && (original.content?.count ?? 0) > maxBlocks {
                blocks.append(json(["type": "typeflux_truncated", "omitted_blocks": (original.content?.count ?? 0) - index]))
                result.truncated = true
                break
            }
            let object = object(raw)
            if raw.data.count > 600000 || total + raw.data.count > maxBytes - 16000 || ((object["type"] as? String).map { $0.isEmpty || $0.utf8.count > 128 } ?? true) {
                blocks.append(json(["type": "typeflux_truncated", "original_type": clip(object["type"] as? String ?? "invalid", bytes: 128), "original_bytes": raw.data.count]))
                result.truncated = true
            } else { blocks.append(raw); total += raw.data.count }
        }
        result.content = blocks
        return result
    }

    /// Read-only preparation. Failure retains the original result and never repeats its producer.
    static func prepare(_ original: AskExecutionOutcome, limit: Int = 4,
                        normalize: (@Sendable (Data, MediaImageType) async throws -> String)? = nil,
                        normalizer: AskToolImageNormalizer = .shared,
                        readImage: ImageReader = { imageInput(object($0)) }) async -> AskExecutionOutcome {
        await prepare(original, limit: limit, batch: normalizer.batch(using: normalize), readImage: readImage)
    }

    private static func prepare(_ original: AskExecutionOutcome, limit: Int,
                                batch: AskToolImageNormalizer.Batch, readImage: ImageReader) async -> AskExecutionOutcome {
        var outcome = bounded(original)
        outcome.preparedImages = [:]
        guard outcome.projectionWithheld != true else { return outcome }
        var attempts = 0, bytes = 0
        for raw in outcome.content ?? [] {
            let block = object(raw)
            guard block["type"] as? String == "image" else { continue }
            guard batch.isCurrent, attempts < min(4, limit) else { break }
            attempts += 1
            guard let input = readImage(raw) else { continue }
            guard batch.isCurrent else { break }
            let key = AskToolPolicy.digest(raw.data)
            do {
                let image = try await batch.normalize(input.data, input.type)
                guard batch.isCurrent, AskToolImageNormalizer.valid(image),
                      bytes + image.utf8.count <= 2_000_000 else { continue }
                bytes += image.utf8.count
                outcome.preparedImages[key] = image
            } catch { /* The outcome, including execution status and raw content, is retained. */ }
        }
        if !batch.isCurrent { withholdImages(&outcome) }
        return outcome
    }

    private static func withholdImages(_ outcome: inout AskExecutionOutcome) {
        guard bounded(outcome).content?.contains(where: { object($0)["type"] as? String == "image" }) == true else { return }
        outcome.preparedImages = [:]
        outcome.projectionWithheld = true
    }

    /// Prepare only a bounded recent window. Older/unavailable images stay explicitly incomplete.
    static func prepareHistory(_ messages: [AskMessage],
                               normalize: (@Sendable (Data, MediaImageType) async throws -> String)? = nil,
                               normalizer: AskToolImageNormalizer = .shared,
                               readImage: ImageReader = { imageInput(object($0)) }) async -> [AskMessage] {
        let batch = normalizer.batch(using: normalize)
        var result = messages, remaining = 8, bytes = 0
        for index in result.indices {
            result[index].harness?.outcome?.preparedImages = [:]
            if result[index].harness?.version == 1, result[index].harness?.outcome?.content != nil { result[index].image = nil }
        }
        for index in messages.indices.suffix(12).reversed() {
            guard remaining > 0, batch.isCurrent else { break }
            guard messages[index].harness?.version == 1, let outcome = messages[index].harness?.outcome,
                  let content = bounded(outcome).content else { continue }
            let count = content.filter { object($0)["type"] as? String == "image" }.count
            guard count > 0 else { continue }
            var prepared = await prepare(outcome, limit: remaining, batch: batch, readImage: readImage)
            remaining -= min(4, count)
            let size = project(prepared).images.reduce(0) { $0 + $1.utf8.count }
            if bytes + size > 2_000_000 { prepared.preparedImages = [:] }
            else { bytes += size }
            result[index].harness?.outcome = prepared
            let projection = project(prepared)
            result[index].image = projection.images.first
            result[index].text = projection.text + (projection.images.count > 1 ? "\n[Multiple images retained; legacy delivery is incomplete]" : "")
            result[index].isError = projection.incomplete || projection.images.count > 1 || prepared.safeStatus != .ok
        }
        if !batch.isCurrent {
            for index in result.indices.suffix(12) {
                guard result[index].harness?.version == 1, var outcome = result[index].harness?.outcome else { continue }
                withholdImages(&outcome)
                result[index].harness?.outcome = outcome
                if outcome.projectionWithheld == true {
                    result[index].image = nil
                    result[index].text = project(outcome).text
                    result[index].isError = true
                }
            }
        }
        return result
    }

    static func imageInput(_ block: [String: Any]) -> (data: Data, type: MediaImageType)? {
        guard let mime = block["mimeType"] as? String, let type = MediaImageType(rawValue: mime),
              let encoded = block["data"] as? String, encoded.utf8.count <= maxBytes,
              let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return (data, type)
    }

    static func project(_ original: AskExecutionOutcome) -> Projection {
        let outcome = bounded(original)
        if outcome.projectionWithheld == true {
            return Projection(text: "[Tool executed; result withheld after cancellation or permission change. Do not replay.]", images: [], incomplete: true)
        }
        var imageBytes = 0
        var texts: [String] = [], images: [String] = []
        var incomplete = outcome.truncated == true
        for raw in outcome.content ?? [] {
            let block = object(raw)
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
                else { texts.append("[Invalid text content]"); incomplete = true }
            case "image":
                if images.count < 4, let image = outcome.preparedImages[AskToolPolicy.digest(raw.data)], imageBytes + image.utf8.count <= 2_000_000 {
                    images.append(image); imageBytes += image.utf8.count; texts.append("[Tool image attached]")
                }
                else { texts.append("[Image retained; projection unavailable or invalid]"); incomplete = true }
            case "structured_content":
                if let value = block["value"], let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                    texts.append("Structured content: " + String(decoding: data, as: UTF8.self))
                } else { texts.append("[Invalid structured content]"); incomplete = true }
            case "resource", "resource_link":
                texts.append("[Resource retained; automatic retrieval is unsupported] " + String(decoding: raw.data, as: UTF8.self)); incomplete = true
            default:
                texts.append("[Unsupported content retained: " + String((block["type"] as? String ?? "unknown").prefix(128)) + "]"); incomplete = true
            }
        }
        if outcome.truncated == true { texts.append("[Tool content was truncated; result is incomplete]") }
        if texts.isEmpty { texts.append("[Tool returned no content]") }
        var text = texts.joined(separator: "\n")
        if text.utf8.count > maxTextBytes {
            text = clip(text, bytes: maxTextBytes) + "\n[Model text projection truncated; retained content is available in history]"
            incomplete = true
        }
        if outcome.safeStatus != .ok { text = "[Tool outcome: " + outcome.safeStatus.rawValue + "]\n" + text }
        return Projection(text: text, images: images, incomplete: incomplete)
    }
}

struct AskResultDiagnostic: Codable, Equatable, Sendable {
    var operationId: String
    var runId: String
    var stepId: String
    var callId: String
    var status: String
    var contentCount: Int
    var truncated: Bool
}

extension AskMessage {
    var resultText: String {
        guard harness?.version == 1, let outcome = harness?.outcome, outcome.content != nil else { return text }
        return AskTypedContent.project(outcome).text
    }
    /// Encoded inputs for an owned asynchronous UI decoder, never a native image getter.
    var retainedResultImages: [String] {
        guard harness?.outcome?.projectionWithheld != true else { return [] }
        guard harness?.version == 1, let content = harness?.outcome?.content else { return image.map { [$0] } ?? [] }
        return AskTypedContent.bounded(.init(status: "ok", content: content)).content?.compactMap { raw in
            let block = AskTypedContent.object(raw)
            guard block["type"] as? String == "image", let input = AskTypedContent.imageInput(block) else { return nil }
            return "data:" + input.type.rawValue + ";base64," + input.data.base64EncodedString()
        }.prefix(4).map { $0 } ?? []
    }
    var resultImages: [String] {
        guard harness?.version == 1, let outcome = harness?.outcome, outcome.content != nil else { return image.map { [$0] } ?? [] }
        return AskTypedContent.project(outcome).images
    }
}

extension AskToolResultRequest {
    func prepared() async -> Self {
        var copy = self
        if harness?.version == 1, let outcome = harness?.outcome, outcome.content != nil {
            copy.harness?.outcome = await AskTypedContent.prepare(outcome)
        }
        return copy
    }

    /// The caller supplies a trusted advertisement pinned to this connection/run.
    /// No capability is inferred from a conversation or model-supplied envelope.
    func forPeer(_ peer: AskHarnessContract?, enabled: Set<AskHarnessCapability> = []) -> Self {
        var copy = legacyProjection()
        if copy.harness?.outcome?.projectionWithheld == true {
            // Keep the private original in the local receipt, not the network envelope.
            copy.harness?.outcome?.content = [AskTypedContent.json(["type": "text", "text": copy.content])]
            copy.harness?.outcome?.artifacts = nil
            copy.harness?.observation = nil
        }
        guard AskTypedContent.advertisement.permits(.typedContent, peer: peer, enabled: enabled) else {
            copy.harness = nil
            return copy
        }
        if copy.harness?.version == 1, var outcome = copy.harness?.outcome, let content = outcome.content {
            // The durable local receipt keeps original blocks. Known images on the
            // network carry only prepared pixels, never an unvalidated fallback.
            let prepared = outcome.preparedImages
            var omitted = false, imageCount = 0, imageBytes = 0
            let wireBlocks = content.map { raw in
                var block = AskTypedContent.object(raw)
                guard block["type"] as? String == "image" else { return raw }
                guard imageCount < 4, let image = prepared[AskToolPolicy.digest(raw.data)],
                      AskToolImageNormalizer.valid(image), imageBytes + image.utf8.count <= 2_000_000 else {
                    omitted = true
                    return AskTypedContent.json(["type": "text", "text": "[Image retained locally; network projection unavailable. Do not replay the tool.]"])
                }
                imageCount += 1; imageBytes += image.utf8.count
                block["mimeType"] = "image/jpeg"
                block["data"] = String(image.dropFirst("data:image/jpeg;base64,".count))
                return AskTypedContent.json(block)
            }
            outcome.content = wireBlocks
            if omitted { outcome.truncated = true }
            outcome = AskTypedContent.bounded(outcome)
            outcome.preparedImages = [:]
            copy.isError = copy.isError || outcome.truncated == true
            copy.harness?.outcome = outcome
        }
        return copy
    }

    func legacyProjection() -> Self {
        var copy = self
        guard let harness else { return copy }
        guard harness.version == 1 else {
            copy.content += "\n[Unsupported result contract version; outcome is unknown.]"
            copy.isError = true
            return copy
        }
        guard let original = harness.outcome else { return copy }
        let outcome = AskTypedContent.bounded(original)
        copy.harness?.outcome = outcome
        if original.content != nil {
            let projection = AskTypedContent.project(outcome)
            copy.content = projection.text
            copy.image = projection.images.first
            if projection.images.count > 1 { copy.content += "\n[Multiple images retained; legacy delivery is incomplete]" }
            copy.isError = isError || projection.incomplete || projection.images.count > 1 || outcome.safeStatus != .ok
        } else { copy.isError = isError || outcome.safeStatus != .ok }
        return copy
    }

    mutating func record(_ output: AskLocalToolOutput) {
        content = output.content; image = output.image; isError = output.isError
        let outcome = output.outcome ?? .init(status: output.isError ? "unknown" : "ok")
        if harness == nil { harness = AskHarnessContract(version: 1) }
        harness?.outcome = outcome
        harness?.observation = output.observation
    }

    func message(step: Int, now: Date) -> AskMessage {
        let id = UUID().uuidString
        let projected = legacyProjection()
        var status = projected.isError ? "unknown" : "ok"
        if let contract = projected.harness {
            status = contract.version == 1 ? (contract.outcome?.safeStatus.rawValue ?? status) : "unknown"
        }
        return AskMessage(id: id, role: "tool", text: projected.content, image: projected.image, toolCallId: toolCallId, isError: projected.isError,
                          createdAt: now, runId: runId, harness: projected.harness,
                          diagnostic: .init(operationId: runId + "/" + toolCallId + "/tool", runId: runId, stepId: String(step), callId: toolCallId,
                                            status: status,
                                            contentCount: projected.harness?.outcome?.content?.count ?? 0, truncated: projected.harness?.outcome?.truncated == true))
    }
}
