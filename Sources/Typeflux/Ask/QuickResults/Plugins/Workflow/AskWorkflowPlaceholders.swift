import Foundation

/// The values an action's fields can use, from one run: `{output}`,
/// `{output.line1}`, `{output.lastLine}`, `{json.a.b}`, `{query}`, `{selection}`,
/// `{keyword}`, `{option:name}`, and `{error}` after a failure.
/// Replacement is plain text in one pass: nothing is evaluated, and text that came
/// in (a query containing `{selection}`) is never expanded again. An unknown name
/// stays as written. See `docs/design/workflow-gallery-output-actions.md` §3.4.
struct AskWorkflowPlaceholders: Equatable, Sendable {
    /// stdout without surrounding white space.
    var output: String
    var query: String
    var selection: String?
    var keyword: String
    var options: [String: String]
    /// Why the run failed and the end of stderr; nil after a success.
    var error: String?

    init(output: String, query: String = "", selection: String? = nil, keyword: String = "",
         options: [String: String] = [:], error: String? = nil) {
        self.output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        self.selection = selection
        self.keyword = keyword
        self.options = options
        self.error = error
    }

    /// Every placeholder the insert menu offers, in its order. `{json.…}` and
    /// `{option:…}` stand for their families.
    static let names = ["output", "output.line1", "output.lastLine", "json.", "query", "selection", "keyword",
                        "option:", "error"]

    /// `template` with each known placeholder replaced. With `urlEncoded`, values that
    /// land after a web link's scheme (`https://x.com/?q={query}`) are percent-encoded; the
    /// fixed text, and a value that is the whole target (`{output}` holding a link), are not.
    func expand(_ template: String, urlEncoded: Bool = false) -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[open...]; break }
            let name = rest[rest.index(after: open) ..< close]
            if let value = value(of: name) {
                let encodes = urlEncoded && ["http", "https"].contains(AskWorkflowAction.scheme(of: result) ?? "")
                result += encodes ? Self.percentEncoded(value) : value
            } else {
                result += rest[open ... close]
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    /// The value of one placeholder; nil when the name is not one.
    func value(of name: Substring) -> String? {
        switch name {
        case "output": return output
        case "output.line1": return lines.first.map(String.init) ?? ""
        case "output.lastLine": return lines.last.map(String.init) ?? ""
        case "query": return query
        case "selection": return selection ?? ""
        case "keyword": return keyword
        case "error": return error ?? ""
        case _ where name.hasPrefix("option:"): return options[String(name.dropFirst(7))] ?? ""
        case _ where name.hasPrefix("json."): return Self.json(at: name.dropFirst(5), in: output) ?? ""
        default: return nil
        }
    }

    /// `{json.…}` placeholders in `template` that find nothing in this output, for the test panel.
    func missingJSON(in template: String) -> [String] {
        Self.names(in: template).filter { name in
            name.hasPrefix("json.") && Self.json(at: name.dropFirst(5), in: output) == nil
        }.map { "{" + $0 + "}" }
    }

    /// The placeholder names a template uses, in order.
    static func names(in template: String) -> [Substring] {
        var names: [Substring] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            names.append(rest[rest.index(after: open) ..< close])
            rest = rest[rest.index(after: close)...]
        }
        return names
    }

    private var lines: [Substring] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
    }

    /// A value in stdout read as JSON, by a dotted path (`items.0.title`). Strings come
    /// as they are, numbers and booleans as JSON writes them, objects and arrays as JSON.
    static func json(at path: Substring, in output: String) -> String? {
        guard !path.isEmpty, let data = output.data(using: .utf8),
              var current = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        for key in path.split(separator: ".", omittingEmptySubsequences: false) {
            if let object = current as? [String: Any], let next = object[String(key)] {
                current = next
            } else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        switch current {
        case let string as String: return string
        case is NSNull: return ""
        case let number as NSNumber
            where CFGetTypeID(number) == CFBooleanGetTypeID(): return number.boolValue ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// Percent-encodes everything but RFC 3986's unreserved characters.
    static func percentEncoded(_ value: String) -> String {
        let unreserved =
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
