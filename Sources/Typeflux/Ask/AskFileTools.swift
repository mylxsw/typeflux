import Foundation

/// File access for Ask, limited to folders the user authorized in Settings.
/// Paths are resolved through symlinks before the check, so a link inside an
/// authorized folder cannot reach outside it.
struct AskFileTools: Sendable {
    static let maximumReadCharacters = 60000
    static let maximumWriteBytes = 1_000_000
    static let maximumListEntries = 500
    static let maximumMatches = 200
    static let maximumSearchFileBytes = 2_000_000

    var roots: [String]

    var resolvedRoots: [URL] {
        roots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL }
    }

    static func definition(roots: [String]) -> AskToolDefinition? {
        guard !roots.isEmpty else { return nil }
        let folders = roots.map { "- " + ($0 as NSString).expandingTildeInPath }.joined(separator: "\n")
        let schema: [String: Any] = [
            "type": "object", "required": ["action", "path"], "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["list", "read", "search", "write", "edit"]],
                "path": ["type": "string", "description": "Absolute path, or relative to the first folder"],
                "pattern": ["type": "string", "description": "search: text to find (case-insensitive)"],
                "content": ["type": "string", "description": "write: full new file content"],
                "old_text": ["type": "string", "description": "edit: exact text to replace (must occur once)"],
                "new_text": ["type": "string", "description": "edit: replacement text"],
                "offset": ["type": "integer", "minimum": 0, "description": "read: first line (0-based)"],
                "limit": ["type": "integer", "minimum": 1, "description": "read: number of lines"]
            ]
        ]
        let description = """
        Read and edit files in the folders the user authorized for Ask (nothing else is reachable):
        \(folders)
        list shows a folder; read returns numbered lines; search finds text in files under a folder; \
        write replaces a whole file; edit replaces one exact, unique snippet. Writes need user approval; \
        prefer edit for small changes and read the file first.
        """
        return AskToolDefinition(name: "files", description: description,
                                 parameters: JSONValue(data: try! JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)))
    }

    static func risk(action: String) -> AskToolRisk {
        ["list", "read", "search"].contains(action) ? .read : .write
    }

    func resolve(_ raw: String, forWriting: Bool = false) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let first = resolvedRoots.first else { throw AskLocalError.message(L("ask.files.denied")) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : first.appendingPathComponent(expanded)
        url = url.standardizedFileURL
        if forWriting {
            // A new file is checked through its nearest existing ancestor, so a
            // symlinked folder on the way cannot lead outside the authorized roots.
            var existing = url
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                missing.insert(existing.lastPathComponent, at: 0)
                existing = existing.deletingLastPathComponent()
            }
            url = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
        } else {
            url = url.resolvingSymlinksInPath()
        }
        let path = url.standardizedFileURL.path
        guard resolvedRoots.contains(where: { path == $0.path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }) else {
            throw AskLocalError.message(L("ask.files.denied"))
        }
        return url.standardizedFileURL
    }

    func execute(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? ""
        let path = args["path"] as? String ?? ""
        switch action {
        case "list": return try list(path)
        case "read": return try read(path, offset: args["offset"] as? Int ?? 0, limit: args["limit"] as? Int)
        case "search":
            guard let pattern = args["pattern"] as? String, !pattern.isEmpty, pattern.count <= 500 else { throw AskLocalError.message(L("ask.tool.invalid")) }
            return try search(path, pattern: pattern)
        case "write":
            guard let content = args["content"] as? String else { throw AskLocalError.message(L("ask.tool.invalid")) }
            return try write(path, content: content)
        case "edit":
            guard let old = args["old_text"] as? String, !old.isEmpty, let new = args["new_text"] as? String else {
                throw AskLocalError.message(L("ask.tool.invalid"))
            }
            return try edit(path, old: old, new: new)
        default: throw AskLocalError.message(L("ask.tool.invalid"))
        }
    }

    func list(_ path: String) throws -> String {
        let url = try resolve(path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var lines = ["Folder: \(url.path)"]
        for item in items.prefix(Self.maximumListEntries) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            lines.append(values?.isDirectory == true ? "\(item.lastPathComponent)/" : "\(item.lastPathComponent)  \(values?.fileSize ?? 0) bytes")
        }
        if items.count > Self.maximumListEntries { lines.append("[\(items.count - Self.maximumListEntries) more entries]") }
        if items.isEmpty { lines.append("(empty)") }
        return lines.joined(separator: "\n")
    }

    func read(_ path: String, offset: Int, limit: Int?) throws -> String {
        let url = try resolve(path)
        let text = try Self.text(at: url)
        let lines = text.components(separatedBy: "\n")
        let start = min(max(0, offset), lines.count)
        let end = start + min(lines.count - start, max(1, limit ?? lines.count))
        var out = "File: \(url.path) (\(lines.count) lines)\n"
        for index in start ..< end {
            let line = "\(index + 1)\t\(lines[index])\n"
            if out.count + line.count > Self.maximumReadCharacters {
                out += "[truncated at line \(index + 1); read again with offset \(index)]"
                return out
            }
            out += line
        }
        return out
    }

    func search(_ path: String, pattern: String) throws -> String {
        let root = try resolve(path)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let files: [URL] = isDirectory.boolValue
            ? (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])?
                .compactMap { $0 as? URL } ?? [])
            : [root]
        var matches: [String] = []
        for file in files {
            // Enumeration can yield a symlinked file outside the grant.
            guard (try? resolve(file.path)) != nil else { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, (values?.fileSize ?? 0) <= Self.maximumSearchFileBytes,
                  let text = try? Self.text(at: file) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.range(of: pattern, options: .caseInsensitive) != nil {
                matches.append("\(file.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces).prefix(200))")
                if matches.count >= Self.maximumMatches {
                    return matches.joined(separator: "\n") + "\n[more matches omitted]"
                }
            }
        }
        return matches.isEmpty ? "No matches." : matches.joined(separator: "\n")
    }

    func write(_ path: String, content: String) throws -> String {
        guard content.utf8.count <= Self.maximumWriteBytes else { throw AskLocalError.message(L("ask.files.tooLarge")) }
        let url = try resolve(path, forWriting: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        return "\(existed ? "Replaced" : "Created") \(url.path) (\(content.utf8.count) bytes)."
    }

    func edit(_ path: String, old: String, new: String) throws -> String {
        let url = try resolve(path)
        let text = try Self.text(at: url)
        let count = text.components(separatedBy: old).count - 1
        guard count == 1 else {
            throw AskLocalError.message(count == 0 ? L("ask.files.editMissing") : L("ask.files.editAmbiguous", count))
        }
        let updated = text.replacingOccurrences(of: old, with: new)
        guard updated.utf8.count <= Self.maximumWriteBytes else { throw AskLocalError.message(L("ask.files.tooLarge")) }
        try Data(updated.utf8).write(to: url, options: .atomic)
        return "Edited \(url.path)."
    }

    /// UTF-8 text only; files with NUL bytes are treated as binary.
    static func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw AskLocalError.message(L("ask.files.binary"))
        }
        return text
    }
}
