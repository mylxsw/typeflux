import Foundation

enum OpenAICompatibleResponseSupport {
    static func applyProviderTuning(body: inout [String: Any], baseURL: URL, model: String) {
        guard shouldDisableThinking(baseURL: baseURL, model: model) else { return }
        body["thinking"] = ["type": "disabled"]
    }

    static func extractTextDelta(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first else {
            return nil
        }

        if let delta = choice["delta"] as? [String: Any],
           let text = extractText(from: delta["content"]) {
            return text
        }

        if let delta = choice["delta"] as? [String: Any],
           let text = extractText(from: delta["text"]) {
            return text
        }

        if let message = choice["message"] as? [String: Any],
           let text = extractText(from: message["content"]) {
            return text
        }

        return nil
    }

    static func containsReasoningDelta(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] else {
            return false
        }

        if let reasoning = delta["reasoning_content"] as? String {
            return !reasoning.isEmpty
        }

        if let reasoning = extractText(from: delta["reasoning_content"]) {
            return !reasoning.isEmpty
        }

        return false
    }

    static func shouldDisableThinking(baseURL: URL, model: String) -> Bool {
        let host = baseURL.host?.lowercased() ?? ""
        let normalizedModel = model.lowercased()
        return host.contains("volces.com")
            || host.contains("bytedance.net")
            || normalizedModel.contains("doubao")
    }

    private static func extractText(from value: Any?) -> String? {
        switch value {
        case let string as String:
            return string.isEmpty ? nil : string

        case let parts as [[String: Any]]:
            let segments = parts
                .compactMap { part -> String? in
                    if let type = part["type"] as? String, type != "text", type != "output_text" {
                        return nil
                    }
                    if let text = part["text"] as? String {
                        return text
                    }
                    if let nested = part["content"] as? String {
                        return nested
                    }
                    return nil
                }
            let text = joinSegmentsPreservingBlocks(segments)
            return text.isEmpty ? nil : text

        case let parts as [Any]:
            let segments = parts
                .compactMap { item -> String? in
                    if let text = item as? String {
                        return text
                    }
                    if let dict = item as? [String: Any] {
                        return extractText(from: dict)
                    }
                    return nil
                }
            let text = joinSegmentsPreservingBlocks(segments)
            return text.isEmpty ? nil : text

        case let dict as [String: Any]:
            if let text = dict["text"] as? String {
                return text.isEmpty ? nil : text
            }
            if let content = dict["content"] {
                return extractText(from: content)
            }
            return nil

        default:
            return nil
        }
    }

    private static func joinSegmentsPreservingBlocks(_ segments: [String]) -> String {
        guard !segments.isEmpty else { return "" }

        return segments.enumerated().reduce(into: "") { partial, item in
            let segment = item.element
            guard !segment.isEmpty else { return }

            if item.offset == 0 {
                partial = segment
                return
            }

            let previous = partial
            let separator: String

            if previous.hasSuffix("\n") || segment.hasPrefix("\n") {
                separator = ""
            } else if beginsMarkdownBlock(segment) || endsAsParagraph(previous) {
                separator = "\n\n"
            } else {
                separator = ""
            }

            partial += separator + segment
        }
    }

    private static func beginsMarkdownBlock(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }

        if ["#", "-", "*", ">", "`"].contains(first) {
            return true
        }

        if first.isNumber {
            let prefix = trimmed.prefix(4)
            return prefix.contains(".")
        }

        return false
    }

    private static func endsAsParagraph(_ string: String) -> Bool {
        guard let last = string.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return [".", "!", "?", "。", "！", "？", ":" , "："].contains(last)
    }
}
