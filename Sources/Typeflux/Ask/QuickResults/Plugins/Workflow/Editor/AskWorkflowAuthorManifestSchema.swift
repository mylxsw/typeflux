import CoreFoundation
import Foundation

/// The tool contract and its structural checks share one definition. Semantic
/// validation (keywords, paths, runtimes and actions) remains in the manifest.
enum AskWorkflowAuthorManifestSchema {
    static var definition: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "object", "additionalProperties": string]
        let action = object(["action": string].merging(
            Dictionary(uniqueKeysWithValues: AskWorkflowAction.Field.allCases.map { ($0.rawValue, string) })
        ) { first, _ in first }, required: ["action"])
        let actions: [String: Any] = ["type": "array", "items": action, "maxItems": 8]
        var output = object([
            "display": ["type": "string", "enum": AskWorkflowManifest.Output.Display.allCases.map(\.rawValue)],
            "onSuccess": actions, "onFailure": actions,
            "close": ["type": "boolean"], "scriptActions": ["type": "boolean"]
        ])
        output["type"] = ["string", "object"]
        return object([
            "schema": ["type": "integer", "enum": [1]],
            "id": string, "name": string, "description": string, "icon": string,
            "version": string, "author": string,
            "keywords": [
                "type": "array", "minItems": 1,
                "description": "A JSON array, e.g. [{\"keyword\":\"weather\"}]. Never wrap it in an item object.",
                "items": object(["keyword": string, "title": string, "script": string, "options": strings],
                                required: ["keyword"])
            ],
            "input": object([
                "argument": ["type": "string", "enum": ["required", "optional", "none"]],
                "selection": ["type": "string", "enum": ["ifEmpty", "never", "always"]]
            ]),
            "run": object([
                "mode": ["type": "string", "enum": ["onSubmit"]],
                "timeoutSeconds": ["type": "number", "minimum": 1, "maximum": 300]
            ]),
            "command": object([
                "runtime": ["type": "string", "enum": ["python3", "node", "typescript", "zsh", "bash", "osascript", "exec"]],
                "script": string, "inline": string, "interpreter": string,
                "args": ["type": "array", "items": string,
                         "description": "A JSON array of argv strings, e.g. [\"{query}\"]. Never use {\"item\":...}."]
            ], required: ["runtime"]),
            "output": output, "env": strings,
            "origin": object(["gallery": string, "version": string], required: ["gallery", "version"])
        ], required: ["id", "name", "command"])
    }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    static func problems(_ manifest: [String: Any]) -> [[String: Any]] {
        check(manifest, schema: definition, path: "")
    }

    /// Collect all shape errors instead of letting JSONDecoder hide the second
    /// malformed array behind the first. Unknown keys are preserved for editors.
    private static func check(_ value: Any, schema: [String: Any], path: String) -> [[String: Any]] {
        let expected = schema["type"] as? [String] ?? [schema["type"] as? String ?? "object"]
        let actual = type(of: value)
        guard expected.contains(actual) || (actual == "integer" && expected.contains("number")) else {
            var message = "Expected \(expected.joined(separator: " or ")), received \(actual)."
            if expected.contains("array") {
                message += " Use a JSON array [...], not an object or an {\"item\":...} wrapper."
            }
            if let description = schema["description"] as? String { message += " " + description }
            return [["field": path, "message": message, "expected": expected, "actual": actual]]
        }
        var problems: [[String: Any]] = []
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = schema["required"] as? [String] ?? []
            for key in required where object[key] == nil || object[key] is NSNull {
                problems.append(["field": field(key, parent: path), "message": "Missing required field \(key)."])
            }
            for key in object.keys.sorted() {
                guard let child = properties[key] ?? schema["additionalProperties"] as? [String: Any],
                      let value = object[key] else { continue }
                // Codable's optional fields accept null as an omitted value.
                if value is NSNull && !required.contains(key) && properties[key] != nil { continue }
                problems += check(value, schema: child, path: field(key, parent: path))
            }
        } else if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, value) in array.enumerated() {
                problems += check(value, schema: items, path: "\(path)[\(index)]")
            }
        }
        return problems
    }

    private static func field(_ key: String, parent: String) -> String {
        parent.isEmpty ? key : parent + "." + key
    }

    private static func type(of value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
            return number.doubleValue.rounded() == number.doubleValue ? "integer" : "number"
        }
        return "unknown"
    }
}
