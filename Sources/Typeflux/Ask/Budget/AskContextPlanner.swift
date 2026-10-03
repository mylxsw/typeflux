import Foundation

struct AskContextLimits: Codable, Equatable, Sendable {
    var window = 32768
    var maxOutput = 4096
    var imageTokens = 16384
    var known = false
}

struct AskContextPlan {
    var payload: [String: Any]
    var inputTokens: Int
    var outputReserve: Int
    var capacity: Int
    var trimmed = false
}

/// Budget only the request projection; durable history and provenance stay intact.
/// Byte accounting is conservative for ordinary text, but model tokenization and
/// image expansion are estimates, including when the model window is known.
enum AskContextPlanner {
    /// Cloud orchestration cannot know a custom provider's current window. The
    /// device validates it before dispatch without increasing the reservation.
    static func devicePayload(_ raw: String, model: RegisteredModel, budgeted: Bool) throws -> String {
        guard budgeted else { return raw }
        guard let payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw AskBudgetError.invalid }
        let limits = AskContextLimits(window: model.contextWindowTokens ?? 32768,
                                      maxOutput: model.maxOutputTokens ?? 4096, known: model.contextWindowTokens != nil)
        return try AskLocalPrompt.json(plan(payload, limits: limits).payload)
    }

    static func plan(_ payload: [String: Any], limits: AskContextLimits) throws -> AskContextPlan {
        guard (512 ... 10_000_000).contains(limits.window), (1 ... 128_000).contains(limits.maxOutput),
              (1 ... 1_000_000).contains(limits.imageTokens),
              JSONSerialization.isValidJSONObject(payload) else { throw AskBudgetError.invalid }
        var copy = payload
        let output = min(payload["max_tokens"] as? Int ?? limits.maxOutput, limits.maxOutput, limits.window / 4)
        guard output > 0 else { throw AskBudgetError.invalid }
        copy["max_tokens"] = output
        let available = limits.window - output - 256
        var plan = AskContextPlan(
            payload: copy,
            inputTokens: weight(copy, imageTokens: limits.imageTokens),
            outputReserve: output,
            capacity: limits.window
        )
        if plan.inputTokens <= available {
            return plan
        }
        var messages = copy["messages"] as? [[String: Any]] ?? []
        for size in [4096, 1024, 256] {
            let changed = trimToolOutputs(&messages, size: size)
            plan.trimmed = plan.trimmed || changed
            copy["messages"] = messages
            plan.inputTokens = weight(copy, imageTokens: limits.imageTokens)
            plan.payload = copy
            if plan.inputTokens <= available {
                return plan
            }
        }
        for index in messages.indices {
            guard var parts = messages[index]["content"] as? [[String: Any]] else { continue }
            for part in parts.indices where parts[part]["type"] as? String == "image_url" {
                parts[part] = [
                    "type": "text",
                    "text": "[Image omitted because the context budget is full; do not infer its contents.]"
                ]
                plan.trimmed = true
            }
            messages[index]["content"] = parts
        }
        copy["messages"] = messages
        plan.payload = copy
        plan.inputTokens = weight(copy, imageTokens: limits.imageTokens)
        guard plan.inputTokens <= available else { throw AskBudgetError.reached("context_capacity") }
        return plan
    }

    private static func trimToolOutputs(_ messages: inout [[String: Any]], size: Int) -> Bool {
        var changed = false
        for index in messages.indices where messages[index]["role"] as? String == "tool" {
            guard let text = messages[index]["content"] as? String,
                  !text.hasPrefix("Tool failed"), !text.hasPrefix("Cancelled"),
                  text.utf8.count > size else { continue }
            messages[index]["content"] = excerpt(text, size: size)
            changed = true
        }
        return changed
    }

    static func excerpt(_ text: String, size: Int) -> String {
        let marker = "\n[Tool output omitted to fit context; incomplete evidence.]\n"
        guard text.utf8.count > size else { return text }
        let count = max(0, (size - marker.utf8.count) / 2)
        let bytes = Array(text.utf8)
        var head = count, tail = bytes.count - count
        while head > 0, bytes[head] & 0xC0 == 0x80 {
            head -= 1
        }
        while tail < bytes.count, bytes[tail] & 0xC0 == 0x80 {
            tail += 1
        }
        return (String(bytes: bytes[..<head], encoding: .utf8) ?? "") + marker + (String(
            bytes: bytes[tail...],
            encoding: .utf8
        ) ?? "")
    }

    static func weight(_ value: Any, imageTokens: Int) -> Int {
        if let object = value as? [String: Any] {
            if object["type"] as? String == "image_url" {
                return imageTokens
            }
            return 16 + object.reduce(0) { $0 + $1.key.utf8.count + weight($1.value, imageTokens: imageTokens) }
        }
        if let list = value as? [Any] {
            return 8 + list.reduce(0) { $0 + weight($1, imageTokens: imageTokens) }
        }
        if let text = value as? String {
            return text.utf8.count + 4
        }
        return 16
    }
}
