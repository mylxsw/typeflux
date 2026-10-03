import CoreFoundation
import Foundation

struct MCPInputError: LocalizedError {
    let path: String
    let reason: String
    var errorDescription: String? { "Invalid tool input at \(path): \(reason)" }
}

/// Offline, bounded JSON Schema subset. Unknown validation keywords/dialects fail
/// closed instead of pretending to enforce them. No URI loader is installed.
enum MCPInputValidator {
    private static let annotations: Set<String> = ["title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "$comment"]
    private static let keywords: Set<String> = ["type", "properties", "required", "additionalProperties", "$ref", "$defs", "definitions", "$schema", "enum", "const", "oneOf", "anyOf", "allOf", "not", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "items", "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties"]

    static func validate(arguments: String, schema: MCPObjectSchema) throws -> [String: Any] {
        guard arguments.utf8.count <= 256000,
              let value = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)),
              let object = value as? [String: Any] else { throw MCPInputError(path: "$", reason: "expected a JSON object") }
        let root = schema.raw.mapValues(\.value)
        try check(schema: schema)
        var budget = 10000
        try match(value, schema: root, root: root, path: "$", depth: 0, budget: &budget)
        return object
    }

    static func check(schema: MCPObjectSchema) throws {
        let root = schema.raw.mapValues(\.value)
        guard schema.type == "object", let data = try? JSONEncoder().encode(schema), data.count <= 32000 else {
            throw MCPInputError(path: "$", reason: "schema must be an object within 32 KB")
        }
        var refs = Set<String>()
        try check(root, root: root, path: "$", depth: 0, refs: &refs)
    }

    private static func bool(_ value: Any) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    private static func failure(_ path: String, _ reason: String) -> MCPInputError { .init(path: path, reason: reason) }

    private static func resolve(_ ref: String, root: [String: Any], path: String) throws -> Any {
        if ref == "#" { return root }
        guard ref.hasPrefix("#/"), let pointer = ref.dropFirst(2).removingPercentEncoding else {
            throw failure(path, "only local JSON Pointer references are supported")
        }
        var result: Any = root
        for token in pointer.components(separatedBy: "/") {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = (result as? [String: Any])?[key] else { throw failure(path, "unresolved local reference") }
            result = next
        }
        return result
    }

    private static func check(_ value: Any, root: [String: Any], path: String, depth: Int, refs: inout Set<String>) throws {
        guard depth <= 64 else { throw failure(path, "schema nesting limit exceeded") }
        if bool(value) != nil { return }
        guard let s = value as? [String: Any] else { throw failure(path, "expected a schema object or boolean") }
        for key in s.keys.sorted() where !keywords.contains(key) && !annotations.contains(key) {
            throw failure(path + "/" + key, "unsupported schema keyword")
        }
        if let dialect = s["$schema"] as? String, dialect != "https://json-schema.org/draft/2020-12/schema" {
            throw failure(path, "unsupported schema dialect")
        }
        if let v = s["$schema"], !(v is String) { throw failure(path, "invalid schema dialect") }
        if let v = s["type"] {
            let types = (v as? String).map { [$0] } ?? (v as? [String] ?? [])
            guard !types.isEmpty, types.allSatisfy({ ["object", "array", "string", "integer", "number", "boolean", "null"].contains($0) }) else { throw failure(path, "invalid type") }
        }
        if let v = s["required"], !(v is [String]) { throw failure(path, "invalid required list") }
        if let v = s["enum"], (v as? [Any])?.isEmpty != false { throw failure(path, "invalid enum") }
        for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"] {
            if let v = s[key] {
                guard let n = number(v), n.isFinite,
                      (key != "multipleOf" || n > 0),
                      (!["minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties"].contains(key) || (n >= 0 && n.rounded() == n)) else { throw failure(path + "/" + key, "invalid numeric constraint") }
            }
        }
        if let v = s["uniqueItems"], bool(v) == nil { throw failure(path, "invalid uniqueItems") }
        for key in ["properties", "$defs", "definitions"] {
            if let v = s[key] {
                guard let entries = v as? [String: Any] else { throw failure(path, "invalid schema map") }
                for name in entries.keys.sorted() { try check(entries[name]!, root: root, path: path + "/" + key + "/" + name, depth: depth + 1, refs: &refs) }
            }
        }
        for key in ["oneOf", "anyOf", "allOf"] {
            if let v = s[key] {
                guard let entries = v as? [Any], !entries.isEmpty else { throw failure(path, "invalid combinator") }
                for entry in entries { try check(entry, root: root, path: path + "/" + key, depth: depth + 1, refs: &refs) }
            }
        }
        for key in ["items", "additionalProperties", "not"] {
            if let child = s[key] { try check(child, root: root, path: path + "/" + key, depth: depth + 1, refs: &refs) }
        }
        if let v = s["$ref"] {
            guard let ref = v as? String else { throw failure(path, "invalid reference") }
            let child = try resolve(ref, root: root, path: path)
            if refs.insert(ref).inserted { try check(child, root: root, path: path + "/$ref", depth: depth + 1, refs: &refs) }
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if bool(a) != nil || bool(b) != nil { return bool(a) != nil && bool(a) == bool(b) }
        if let x = number(a), let y = number(b) { return x == y }
        if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy(equal) }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return x.count == y.count && x.allSatisfy { key, value in y[key].map { equal(value, $0) } ?? false }
        }
        return (a as? NSObject)?.isEqual(b) == true
    }

    private static func match(_ value: Any, schema: Any, root: [String: Any], path: String, depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 64, budget >= 0 else { throw failure(path, "validation complexity limit exceeded") }
        if let allowed = bool(schema) { if !allowed { throw failure(path, "value is forbidden") }; return }
        guard let s = schema as? [String: Any] else { throw failure(path, "invalid schema") }
        if let ref = s["$ref"] as? String { try match(value, schema: resolve(ref, root: root, path: path), root: root, path: path, depth: depth + 1, budget: &budget) }
        if let type = s["type"] {
            let types = (type as? String).map { [$0] } ?? (type as? [String] ?? [])
            let valid = types.contains { type in
                switch type {
                case "object": return value is [String: Any]
                case "array": return value is [Any]
                case "string": return value is String
                case "boolean": return bool(value) != nil
                case "null": return value is NSNull
                case "number": return number(value) != nil
                case "integer": return number(value).map { $0.rounded() == $0 } ?? false
                default: return false
                }
            }
            if !valid { throw failure(path, "expected " + types.joined(separator: " or ")) }
        }
        if let values = s["enum"] as? [Any], !values.contains(where: { equal(value, $0) }) { throw failure(path, "value is outside enum") }
        if let expected = s["const"], !equal(value, expected) { throw failure(path, "value differs from const") }
        for key in ["allOf", "anyOf", "oneOf"] {
            if let branches = s[key] as? [Any] {
                var successes = 0
                for branch in branches {
                    do { try match(value, schema: branch, root: root, path: path, depth: depth + 1, budget: &budget); successes += 1 }
                    catch let error as MCPInputError {
                        if error.reason.contains("complexity") { throw error }
                        if key == "allOf" { throw error }
                    }
                }
                if (key == "anyOf" && successes == 0) || (key == "oneOf" && successes != 1) { throw failure(path, key + " constraint failed") }
            }
        }
        if let child = s["not"] {
            var matches = true
            do { try match(value, schema: child, root: root, path: path, depth: depth + 1, budget: &budget) }
            catch let error as MCPInputError { if error.reason.contains("complexity") { throw error }; matches = false }
            if matches { throw failure(path, "not constraint failed") }
        }
        if let n = number(value) {
            for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"] {
                guard let limit = number(s[key]) else { continue }
                let valid: Bool
                switch key {
                case "minimum": valid = n >= limit
                case "maximum": valid = n <= limit
                case "exclusiveMinimum": valid = n > limit
                case "exclusiveMaximum": valid = n < limit
                default: let ratio = n / limit; valid = ratio.isFinite && abs(ratio - ratio.rounded()) <= 1e-10
                }
                if !valid { throw failure(path, key + " constraint failed") }
            }
        }
        func length(_ count: Int, _ low: String, _ high: String) throws {
            if let n = number(s[low]), Double(count) < n { throw failure(path, low + " constraint failed") }
            if let n = number(s[high]), Double(count) > n { throw failure(path, high + " constraint failed") }
        }
        if let text = value as? String { try length(text.unicodeScalars.count, "minLength", "maxLength") }
        if let array = value as? [Any] {
            try length(array.count, "minItems", "maxItems")
            if let child = s["items"] { for (i, v) in array.enumerated() { try match(v, schema: child, root: root, path: path + "/\(i)", depth: depth + 1, budget: &budget) } }
            if let unique = s["uniqueItems"], bool(unique) == true {
                for i in array.indices { for j in 0..<i { budget -= 1; if budget < 0 { throw failure(path, "validation complexity limit exceeded") }; if equal(array[i], array[j]) { throw failure(path + "/\(i)", "duplicate array item") } } }
            }
        }
        if let object = value as? [String: Any] {
            try length(object.count, "minProperties", "maxProperties")
            for key in s["required"] as? [String] ?? [] where object[key] == nil { throw failure(path + "/" + key, "required field is missing") }
            let properties = s["properties"] as? [String: Any] ?? [:]
            for key in object.keys.sorted() {
                if let child = properties[key] ?? s["additionalProperties"] { try match(object[key]!, schema: child, root: root, path: path + "/" + key, depth: depth + 1, budget: &budget) }
            }
        }
    }
}
