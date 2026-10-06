import Foundation

/// What the editor's Files card says about each file (§2.3): which keywords start
/// it, and which files use it, found by a simple scan for Python `import x`, Node
/// `require('./x')` / `import … from './x'` and shell `source ./x`. A file the scan
/// cannot place gets no line; nothing here runs or parses code.
enum AskWorkflowFileReferences {
    /// One file using another: "main.py" with "import rates".
    struct Reference: Equatable, Sendable {
        var from: String
        var statement: String
    }

    /// One row of the Files card.
    struct Row: Equatable, Sendable {
        var path: String
        /// The keywords this file is the entry of; empty when it is not an entry.
        var keywords: [String]
        /// It is `command.script`, the entry of every keyword without its own.
        var isDefault: Bool
        var references: [Reference]

        var isEntry: Bool {
            isDefault || !keywords.isEmpty
        }
    }

    /// A row per file, entries first (the default one leading), then the others by name.
    static func rows(manifest: AskWorkflowManifest?, files: [String: String]) -> [Row] {
        let used = references(in: files)
        let rows = files.keys.map { path -> Row in
            let isDefault = manifest?.command.script == path
            let keywords = (manifest?.keywords ?? []).filter { ($0.script ?? manifest?.command.script) == path }
                .map(\.keyword)
            return Row(path: path, keywords: keywords, isDefault: isDefault, references: used[path] ?? [])
        }
        return rows.sorted { first, second in
            if first.isDefault != second.isDefault {
                return first.isDefault
            }
            if first.isEntry != second.isEntry {
                return first.isEntry
            }
            return first.path < second.path
        }
    }

    /// For each file, the other files that use it.
    static func references(in files: [String: String]) -> [String: [Reference]] {
        var result: [String: [Reference]] = [:]
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            for (target, statement) in targets(in: text, of: path) where target != path && files[target] != nil {
                let reference = Reference(from: path, statement: statement)
                if result[target]?.contains(reference) != true {
                    result[target, default: []].append(reference)
                }
            }
        }
        return result
    }

    private static let python = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:from[ \t]+\.?([A-Za-z_][\w.]*)[ \t]+import\b|import[ \t]+([A-Za-z_][\w.]*))"#,
        options: .anchorsMatchLines
    )
    private static let node = try? NSRegularExpression(
        pattern: #"(?:require\(\s*|\bfrom\s+|\bimport\s+)['"]\./([^'"]+)['"]"#
    )
    private static let shell = try? NSRegularExpression(
        pattern: #"^[ \t]*(?:source|\.)[ \t]+["']?(?:\$\{?TYPEFLUX_WORKFLOW_DIR\}?/|\./)?([\w./-]+)"#,
        options: .anchorsMatchLines
    )

    /// The workflow files `text` (the file at `path`) refers to, with the statement that does.
    static func targets(in text: String, of path: String) -> [(path: String, statement: String)] {
        let range = NSRange(text.startIndex..., in: text)
        let fileExtension = (path as NSString).pathExtension.lowercased()
        var found: [(String, String)] = []
        func each(_ pattern: NSRegularExpression?, _ handle: (NSTextCheckingResult) -> Void) {
            pattern?.matches(in: text, range: range).forEach(handle)
        }
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        switch fileExtension {
        case "py":
            each(python) { match in
                guard let module = group(match, 1) ?? group(match, 2) else { return }
                let line = group(match, 1) == nil ? "import " + module : "from \(module) import …"
                found.append((module.replacingOccurrences(of: ".", with: "/") + ".py", line))
            }
        case "js", "mjs", "cjs", "ts", "mts":
            each(node) { match in
                guard let target = group(match, 1) else { return }
                let named = (target as NSString).pathExtension.isEmpty ? target + "." + fileExtension : target
                found.append((named, "require('./\(target)')"))
            }
        case "sh", "zsh", "bash", "":
            each(shell) { match in
                guard let target = group(match, 1) else { return }
                found.append((target, "source ./" + target))
            }
        default:
            break
        }
        return found
    }
}
