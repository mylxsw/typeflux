import Foundation

/// Value-only definition and parser shared by the built-in host and compatibility callers.
enum AskBuiltinPlan {
    static let usageInstruction = "Create or maintain an execution plan or progress checklist with update_plan only when the user explicitly asks for that plan or checklist. Otherwise execute the requested work directly, regardless of complexity or number of steps. Do not ask the user whether they want a plan. A saved plan or checklist is historical context, not permission to create or maintain one."

    static let definition = AskToolDefinition(
        name: "update_plan",
        description: usageInstruction + " "
            + "Send the complete list every time; preserve completed work and mark at most one step in_progress. Mark only verified steps completed. Keep unfinished steps pending; an unfinished checklist alone is not a blocker. Use outcome needs_input/blocked only for a concrete missing user input or external obstacle. Request actual tools for host approval, not verbal permission.",
        // The fixed schema is a JSON-compatible literal, matching the original definition.
        // swiftlint:disable:next force_try
        parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: [
            "type": "object", "required": ["items"], "additionalProperties": false,
            "properties": [
                "outcome": ["type": "string", "enum": ["completed", "needs_input", "blocked"]],
                "reason": ["type": "string", "maxLength": 1000],
                "items": ["type": "array", "minItems": 1, "maxItems": 20, "items": [
                "type": "object", "required": ["step", "status"], "additionalProperties": false,
                "properties": [
                    "step": ["type": "string"],
                    "status": ["type": "string", "enum": ["pending", "in_progress", "completed"]]
                ]
            ]]]
        ], options: .sortedKeys))
    )

    static func parse(_ arguments: String) throws -> [AskPlanItem] {
        let args = try AskLocalTools.jsonArguments(arguments)
        guard let raw = args["items"] as? [[String: Any]], (1 ... 20).contains(raw.count) else {
            throw AskLocalError.message("items must list 1 to 20 steps")
        }
        var active = 0
        let items = try raw.map { item -> AskPlanItem in
            let step = (item["step"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = item["status"] as? String ?? ""
            guard !step.isEmpty,
                  step.count <= 300 else { throw AskLocalError.message("Each step needs 1 to 300 characters") }
            guard ["pending", "in_progress", "completed"].contains(status) else {
                throw AskLocalError.message("status must be pending, in_progress or completed")
            }
            if status == "in_progress" {
                active += 1
            }
            return AskPlanItem(step: step, status: status)
        }
        guard active <= 1 else { throw AskLocalError.message("Mark at most one step in_progress") }
        _ = try AskTaskResolution.parse(arguments, items: items)
        return items
    }
}
