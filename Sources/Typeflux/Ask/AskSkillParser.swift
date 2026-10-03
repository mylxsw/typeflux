import Foundation
import Yams

/// The supported frontmatter schema is documented in docs/ask-skills.md.
/// YAML syntax is handled by Yams; this layer deliberately accepts only a small schema.
enum AskSkillParser {
    static let maximumHeaderBytes = 32_768

    enum Failure: String, LocalizedError {
        case malformed, unsupported, invalidSkill

        var errorDescription: String? { L("ask.skills.parse." + rawValue) }
    }

    static func parse(_ text: String, fallbackName: String) throws -> AskSkill {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let content = normalized.hasPrefix("\u{FEFF}") ? String(normalized.dropFirst()) : normalized
        let lines = content.components(separatedBy: "\n")
        var fields: [String: Node] = [:]
        var body = content
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            // A closing delimiter must be at column zero: indented --- belongs to a block scalar.
            guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else {
                throw Failure.malformed
            }
            let header = lines[1..<end].joined(separator: "\n") + "\n"
            guard header.utf8.count <= maximumHeaderBytes else { throw Failure.unsupported }
            do {
                // Keep the parser alive while validating: Yams nodes hold weak anchor references.
                let parser = try Parser(yaml: header)
                let root = try parser.singleRoot()
                fields = try withExtendedLifetime(parser) { try mapping(root) }
            } catch let error as Failure {
                throw error
            } catch {
                throw Failure.malformed
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        let name = try scalar(fields["name"]) ?? fallbackName
        var description = try scalar(fields["description"]) ?? ""
        let slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-")
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty, slug.count <= 64, slug.allSatisfy(\.isASCII), !body.isEmpty else {
            throw Failure.invalidSkill
        }
        if description.isEmpty {
            description = body.components(separatedBy: "\n").first {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
            } ?? slug
        }
        let permissions = try ["allowed-tools", "permissions"].flatMap { key -> [String] in
            guard let node = fields[key] else { return [] }
            if let sequence = node.sequence { return try sequence.map { try scalar($0) ?? "" } }
            return [try scalar(node) ?? ""]
        }.filter { !$0.isEmpty }
        return AskSkill(name: slug,
                        description: String(description.prefix(AskSkillLibrary.maximumDescriptionCharacters)),
                        body: String(body.prefix(AskSkillLibrary.maximumBodyCharacters)),
                        declaredPermissions: permissions, version: try scalar(fields["version"]))
    }

    private static func mapping(_ root: Node?) throws -> [String: Node] {
        guard let root else { return [:] }
        try validate(root, depth: 0)
        guard let mapping = root.mapping else { throw Failure.unsupported }
        var fields: [String: Node] = [:]
        for (key, value) in mapping {
            guard let name = key.scalar?.string, !name.isEmpty, name != "<<", fields[name] == nil else {
                throw Failure.unsupported
            }
            if name == "metadata" {
                guard let metadata = value.mapping, metadata.allSatisfy({ $0.value.scalar != nil }) else {
                    throw Failure.unsupported
                }
            } else if name == "allowed-tools" || name == "permissions" {
                guard value.scalar != nil || value.sequence?.allSatisfy({ $0.scalar != nil }) == true else {
                    throw Failure.unsupported
                }
            } else {
                guard value.scalar != nil else { throw Failure.unsupported }
            }
            fields[name] = value
        }
        return fields
    }

    private static func scalar(_ node: Node?) throws -> String? {
        guard let node else { return nil }
        guard let scalar = node.scalar else { throw Failure.unsupported }
        return scalar.string
    }

    private static func validate(_ node: Node, depth: Int) throws {
        guard depth <= 2, node.anchor == nil else { throw Failure.unsupported }
        let tags = ["str", "int", "float", "bool", "null", "timestamp", "map", "seq"]
        guard tags.contains(where: { node.tag.rawValue == "tag:yaml.org,2002:" + $0 }) else {
            throw Failure.unsupported
        }
        if let mapping = node.mapping {
            var keys = Set<String>()
            for (key, value) in mapping {
                try validate(key, depth: depth + 1)
                guard let name = key.scalar?.string, name != "<<", keys.insert(name).inserted else {
                    throw Failure.unsupported
                }
                try validate(value, depth: depth + 1)
            }
        } else if let sequence = node.sequence {
            for value in sequence { try validate(value, depth: depth + 1) }
        }
    }
}
