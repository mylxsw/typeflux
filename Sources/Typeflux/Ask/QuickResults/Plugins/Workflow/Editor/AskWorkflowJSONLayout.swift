import Foundation

/// Writes `workflow.json` the way the user laid it out: keys keep the order they have
/// in the existing text (new keys follow, sorted), with its indentation. A form edit or
/// an assistant proposal then changes only the lines it means to, not the whole file.
enum AskWorkflowJSONLayout {
    struct Style: Equatable {
        var indent = "  "
        /// `": "`, or `" : "` as Foundation writes it.
        var colon = ": "
    }

    /// `object` as pretty-printed JSON shaped like `original`; sorted keys when there is none.
    static func format(_ object: [String: Any], like original: String? = nil) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        let order = original.map(keyOrder(of:)) ?? [:]
        let style = original.map(style(of:)) ?? Style()
        var writer = Writer(order: order, style: style)
        guard writer.write(object, path: "", depth: 0) else { return nil }
        return writer.output + "\n"
    }

    /// The indentation and colon spacing of pretty-printed JSON.
    static func style(of text: String) -> Style {
        var style = Style()
        let lines = text.components(separatedBy: "\n")
        if let line = lines.first(where: { $0.first == " " || $0.first == "\t" }) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            style.indent = indent.first == "\t" ? "\t" : String(repeating: " ", count: min(max(indent.count, 1), 8))
        }
        if text.contains("\" : ") {
            style.colon = " : "
        }
        return style
    }

    /// Each object's keys in the order they appear, by path: "" for the root,
    /// "command" for a nested object, "keywords.0" for an object in an array.
    static func keyOrder(of text: String) -> [String: [String]] {
        var reader = KeyOrderReader()
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\"" {
                reader.string(readString(&characters))
            } else {
                reader.punctuation(character)
            }
        }
        return reader.order
    }

    /// The rest of a JSON string after its opening quote, unescaped enough to compare keys.
    private static func readString(_ characters: inout String.Iterator) -> String {
        var string = ""
        var escaped = false
        while let next = characters.next() {
            if escaped {
                string.append(next)
                escaped = false
            } else if next == "\\" {
                escaped = true
            } else if next == "\"" {
                break
            } else {
                string.append(next)
            }
        }
        return string
    }

    /// Follows objects and arrays while JSON text is read, noting each object's keys.
    private enum Container {
        case object(path: String, expectingKey: Bool, lastKey: String?)
        case array(path: String, index: Int)
    }

    private struct KeyOrderReader {
        var order: [String: [String]] = [:]
        private var stack: [Container] = []

        /// Where a value opening now goes.
        private var childPath: String {
            switch stack.last {
            case let .object(path, _, key?): path.isEmpty ? key : path + "." + key
            case let .array(path, index): path + "." + String(index)
            default: ""
            }
        }

        mutating func string(_ string: String) {
            guard case let .object(path, true, _) = stack.last else { return }
            stack[stack.count - 1] = .object(path: path, expectingKey: false, lastKey: string)
            if !(order[path]?.contains(string) ?? false) {
                order[path, default: []].append(string)
            }
        }

        mutating func punctuation(_ character: Character) {
            switch character {
            case "{": stack.append(.object(path: childPath, expectingKey: true, lastKey: nil))
            case "[": stack.append(.array(path: childPath, index: 0))
            case "}", "]": _ = stack.popLast()
            case ",": next()
            default: break
            }
        }

        private mutating func next() {
            switch stack.last {
            case let .object(path, _, key):
                stack[stack.count - 1] = .object(path: path, expectingKey: true, lastKey: key)
            case let .array(path, index):
                stack[stack.count - 1] = .array(path: path, index: index + 1)
            case nil:
                break
            }
        }
    }

    /// Writes values with the key order and style it was made with.
    private struct Writer {
        var order: [String: [String]]
        var style: Style
        var output = ""

        mutating func write(_ value: Any, path: String, depth: Int) -> Bool {
            let inner = String(repeating: style.indent, count: depth + 1)
            let outer = String(repeating: style.indent, count: depth)
            switch value {
            case let object as [String: Any]:
                guard !object.isEmpty else { output += "{}"; return true }
                let known = (order[path] ?? []).filter { object[$0] != nil }
                let keys = known + object.keys.filter { !known.contains($0) }.sorted()
                output += "{\n"
                for (offset, key) in keys.enumerated() {
                    output += inner + scalar(key) + style.colon
                    guard let item = object[key], write(item, path: path.isEmpty ? key : path + "." + key,
                                                        depth: depth + 1) else { return false }
                    output += offset == keys.count - 1 ? "\n" : ",\n"
                }
                output += outer + "}"
            case let array as [Any]:
                guard !array.isEmpty else { output += "[]"; return true }
                output += "[\n"
                for (offset, item) in array.enumerated() {
                    output += inner
                    guard write(item, path: path + "." + String(offset), depth: depth + 1) else { return false }
                    output += offset == array.count - 1 ? "\n" : ",\n"
                }
                output += outer + "]"
            default:
                output += scalar(value)
            }
            return true
        }

        /// A string, number, boolean or null as Foundation writes it.
        private func scalar(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }
    }
}
