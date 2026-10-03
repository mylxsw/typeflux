import Foundation
import ImageIO

/// Storage and presentation never grant authority or fetch a resource URI.
enum AskTypedContent {
    static let maxBytes = 1_000_000
    static let maxBlocks = 64
    static let maxTextBytes = 60000
    static let advertisement = AskHarnessContract(version: 1, capabilities: [AskHarnessCapability.typedContent.rawValue])

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

    static func output(from result: MCPToolsCallResult) -> AskLocalToolOutput {
        var blocks = result.content.map(\.raw)
        if let value = result.structuredContent { blocks.append(json(["type": "structured_content", "value": object(value)])) }
        if let value = result.metadata { blocks.append(json(["type": "mcp_metadata", "value": object(value)])) }
        var outcome = bounded(.init(status: result.isError == true ? "unknown" : "ok", content: blocks))
        let projection = project(outcome)
        if projection.incomplete { outcome.truncated = outcome.truncated ?? false }
        let legacyImage = projection.images.first.flatMap { url -> String? in
            guard let comma = url.firstIndex(of: ",") else { return nil }
            return AskLocalTools.jpegDataURL(base64: String(url[url.index(after: comma)...]))
        }
        // A legacy peer must never interpret a partial multi-image result as complete.
        let incomplete = projection.incomplete || projection.images.count > 1
        var text = projection.text
        if projection.images.count > 1 { text += "\n[Multiple images retained; legacy delivery is incomplete]" }
        return AskLocalToolOutput(content: text, image: legacyImage, isError: result.isError == true || incomplete, outcome: outcome)
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

    static func imageURL(_ block: [String: Any]) -> String? {
        guard let mime = block["mimeType"] as? String, ["image/jpeg", "image/png", "image/gif"].contains(mime),
              let encoded = block["data"] as? String, encoded.utf8.count <= maxBytes,
              let data = Data(base64Encoded: encoded), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let kind = CGImageSourceGetType(source) as String?,
              ["image/jpeg": "public.jpeg", "image/png": "public.png", "image/gif": "com.compuserve.gif"][mime] == kind,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 12000000 else { return nil }
        return "data:" + mime + ";base64," + encoded
    }

    static func project(_ outcome: AskExecutionOutcome) -> Projection {
        var texts: [String] = [], images: [String] = []
        var incomplete = outcome.truncated == true
        for raw in outcome.content ?? [] {
            let block = object(raw)
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
                else { texts.append("[Invalid text content]"); incomplete = true }
            case "image":
                if let image = imageURL(block) { images.append(image); texts.append("[Tool image attached]") }
                else { texts.append("[Unsupported or invalid image retained]"); incomplete = true }
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
    var resultImages: [String] {
        guard harness?.version == 1, let outcome = harness?.outcome, outcome.content != nil else { return image.map { [$0] } ?? [] }
        return AskTypedContent.project(outcome).images
    }
}

extension AskToolResultRequest {
    /// The caller supplies a trusted advertisement pinned to this connection/run.
    /// No capability is inferred from a conversation or model-supplied envelope.
    func forPeer(_ peer: AskHarnessContract?, enabled: Set<AskHarnessCapability> = []) -> Self {
        var copy = legacyProjection()
        guard AskTypedContent.advertisement.permits(.typedContent, peer: peer, enabled: enabled) else {
            copy.harness = nil
            return copy
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
            copy.image = projection.images.first.flatMap { url in
                guard let comma = url.firstIndex(of: ",") else { return nil }
                return AskLocalTools.jpegDataURL(base64: String(url[url.index(after: comma)...]))
            }
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
                          diagnostic: .init(operationId: id, runId: runId, stepId: String(step), callId: toolCallId,
                                            status: status,
                                            contentCount: projected.harness?.outcome?.content?.count ?? 0, truncated: projected.harness?.outcome?.truncated == true))
    }
}
