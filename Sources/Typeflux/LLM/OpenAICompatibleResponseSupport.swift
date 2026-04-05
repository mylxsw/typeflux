import Foundation

enum OpenAICompatibleResponseSupport {
    // MARK: - Thinking Tag Filtering

    /// Strips a leading <think>...</think> or <thinking>...</thinking> block (plus any
    /// surrounding whitespace) from the start of a complete response string.
    /// If the tag does not appear at the head of the content (after trimming whitespace),
    /// the original text is returned unchanged.
    static func stripLeadingThinkingTags(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for openTag in ["<thinking>", "<think>"] {
            guard trimmed.lowercased().hasPrefix(openTag) else { continue }
            let closeTag = "</" + openTag.dropFirst()
            let afterOpenTag = trimmed.dropFirst(openTag.count)
            if let closeRange = afterOpenTag.range(of: closeTag, options: .caseInsensitive) {
                let afterClose = afterOpenTag[closeRange.upperBound...]
                return String(afterClose).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break // Malformed: open tag found but no closing tag — leave as-is
        }
        return text
    }

    /// Stateful filter for streaming responses. Suppresses a leading <think>...</think>
    /// block that may arrive across multiple SSE chunks. Once the block ends (or it is
    /// determined that no think block is present), all subsequent chunks pass through
    /// unchanged.
    struct StreamingThinkingFilter {
        private enum State {
            case initial // Accumulating until we know if a think block is present
            case inThinkBlock // Inside a think block; suppress output
            case passThrough // Past the initial section; emit everything
        }

        private var state: State = .initial
        private var buffer = ""

        /// Feed the next streaming chunk. Returns the string to emit, or nil if suppressed.
        mutating func process(_ chunk: String) -> String? {
            switch state {
            case .passThrough:
                return chunk.isEmpty ? nil : chunk

            case .initial:
                buffer += chunk
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil } // Still leading whitespace

                let lower = trimmed.lowercased()
                if lower.hasPrefix("<thinking>") || lower.hasPrefix("<think>") {
                    state = .inThinkBlock
                    return drainThinkBlock()
                } else {
                    state = .passThrough
                    let output = buffer
                    buffer = ""
                    return output
                }

            case .inThinkBlock:
                buffer += chunk
                return drainThinkBlock()
            }
        }

        /// Call after the stream ends to emit any buffered content that was never resolved.
        mutating func flush() -> String? {
            guard !buffer.isEmpty else { return nil }
            let output = buffer
            buffer = ""
            return output
        }

        private mutating func drainThinkBlock() -> String? {
            for closeTag in ["</thinking>", "</think>"] {
                if let range = buffer.range(of: closeTag, options: .caseInsensitive) {
                    let afterClose = String(buffer[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer = ""
                    state = .passThrough
                    return afterClose.isEmpty ? nil : afterClose
                }
            }
            return nil // Still inside think block; keep buffering
        }
    }

    // MARK: - Provider Tuning

    static func applyProviderTuning(body: inout [String: Any], baseURL: URL, model: String) {
        guard shouldDisableThinking(baseURL: baseURL, model: model) else { return }
        body["thinking"] = ["type": "disabled"]
    }

    static func extractTextDelta(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first
        else {
            return nil
        }

        if let delta = choice["delta"] as? [String: Any],
           let text = extractText(from: delta["content"])
        {
            return text
        }

        if let delta = choice["delta"] as? [String: Any],
           let text = extractText(from: delta["text"])
        {
            return text
        }

        if let message = choice["message"] as? [String: Any],
           let text = extractText(from: message["content"])
        {
            return text
        }

        return nil
    }

    static func containsReasoningDelta(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delta = ((object["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
        else {
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
            let separator = if previous.hasSuffix("\n") || segment.hasPrefix("\n") {
                ""
            } else if beginsMarkdownBlock(segment) || endsAsParagraph(previous) {
                "\n\n"
            } else {
                ""
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
        return [".", "!", "?", "。", "！", "？", ":", "："].contains(last)
    }
}
