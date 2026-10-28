import CoreFoundation
import Darwin
import Foundation

/// Bounded file operations under the trusted host's current folder grants.
struct AskFileTools: Sendable {
    static let workspaceInstruction = "Create new projects and generated files in this conversation's workspace (work/ for project sources, outputs/ for final exports), unless the user explicitly requests another destination. Authorized folders are access grants, not default output locations: do not choose Downloads, Desktop or the home folder just because they are accessible. Keep changes to an existing user-selected project in its original folder. Use the exact workspace path supplied by the host; never invent one. When the user has not selected an external project, check the current workspace before reusing project paths from history."

    static let maximumReadCharacters = 60000 // Compatibility name; measured in UTF-8 bytes.
    static let maximumWriteBytes = 1_000_000
    static let maximumListEntries = 500
    static let maximumMatches = 200
    static let maximumSearchFileBytes = 2_000_000
    static let maximumScanBytes = 4 * 1024 * 1024
    static let maximumEditBytes = 16 * 1024 * 1024
    static let maximumPagingValue = 1_000_000_000

    struct Hooks: Sendable {
        var onEvent: (@Sendable (String) throws -> Void)?
        var onBytes: (@Sendable (Int) throws -> Void)?
        var onCommit: (@Sendable () -> Void)?
        var validateGrant: (@Sendable () throws -> Void)?
    }

    var roots: [String]
    var hooks = Hooks()
    var cancellation: AskFileCancellation?

    var resolvedRoots: [URL] {
        roots.map { URL(fileURLWithPath: AskProjectFileAccess.normalizedRoot($0)) }
    }

    static func definition(roots: [String], workspace: URL? = nil) -> AskToolDefinition? {
        guard !roots.isEmpty else { return nil }
        let folders = roots.map { "- " + ($0 as NSString).expandingTildeInPath }.joined(separator: "\n")
        let location: String
        let pathDescription: String
        if let workspace {
            let path = workspace.path
            guard roots.first.map(AskProjectFileAccess.normalizedRoot) == AskProjectFileAccess.normalizedRoot(path)
            else { return nil }
            let otherFolders = roots.dropFirst().map { "- " + ($0 as NSString).expandingTildeInPath }.joined(separator: "\n")
            location = "Conversation workspace (default working directory): " + path
                + "\nNew project directory: " + path + "/work/"
                + "\nFinal export directory: " + path + "/outputs/"
                + (otherFolders.isEmpty ? "" : "\nOther authorized folders (not default output destinations):\n" + otherFolders)
            pathDescription = "Absolute path, or relative to the conversation workspace: " + path
        } else {
            location = "Authorized folders:\n" + folders
            pathDescription = "Absolute path, or relative to the first authorized folder: " + roots[0]
        }
        let schema: [String: Any] = [
            "type": "object", "required": ["action", "path"], "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["list", "read", "search", "write", "edit"]],
                "path": ["type": "string", "description": pathDescription],
                "pattern": ["type": "string", "description": "search: text to find (case-insensitive)"],
                "content": ["type": "string", "description": "write: full new file content"],
                "old_text": ["type": "string", "description": "edit: exact text to replace (must occur once)"],
                "new_text": ["type": "string", "description": "edit: replacement text"],
                "continuation": [
                    "type": "string",
                    "maxLength": 4096,
                    "description": "read: resume an earlier partial read; omit offset and limit"
                ],
                "expected_version": [
                    "type": "string",
                    "description": "write/edit: version from a fresh read; required for existing files"
                ],
                "offset": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 1_000_000_000,
                    "description": "read: first line (0-based)"
                ],
                "limit": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 1_000_000_000,
                    "description": "read: number of lines"
                ]
            ]
        ]
        let description = """
        Read and edit files at the host-provided locations below.
        \(location)
        \(workspace == nil ? "Relative paths start in the first authorized folder." : Self.workspaceInstruction) \
        list shows a folder; read returns numbered lines; search finds text in files under a folder; \
        write replaces a whole file; edit replaces one exact, unique snippet. Writes need user approval; \
        prefer edit for small changes. Read first and supply expected_version for existing files. \
        Reads may be partial; follow continuation without offset/limit. Only consumed text is validated.
        """
        guard let data = try? JSONSerialization.data(withJSONObject: schema, options: .sortedKeys) else { return nil }
        return AskToolDefinition(name: "files", description: description, parameters: JSONValue(data: data))
    }

    static func risk(action: String) -> AskToolRisk {
        ["list", "read", "search"].contains(action) ? .read : .write
    }

    /// Used by approval/recovery and browser permission checks. Execution separately
    /// opens and pins descriptors; this URL never grants authority to reopen a file.
    func resolve(_ raw: String, forWriting: Bool = false) throws -> URL {
        let location = try AskFileAccess.location(raw, roots: roots)
        var directory = try AskFileAccess.openRoot(location.root)
        for (index, part) in location.parts.enumerated() {
            var info = stat()
            if fstatat(directory.descriptor, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if forWriting, errno == ENOENT {
                    break
                }
                throw AskFileAccess.denied
            }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw AskFileAccess.denied }
            if index < location.parts.count - 1 {
                directory = try directory.child(part)
            }
        }
        return URL(fileURLWithPath: location.path)
    }

    func execute(_ args: [String: Any]) throws -> String {
        try Task.checkCancellation()
        if let expected = args["expected_version"], !(expected is String) {
            throw AskFileAccess.error(L("ask.tool.invalid"))
        }
        let action = args["action"] as? String ?? ""
        let path = args["path"] as? String ?? ""
        switch action {
        case "list": return try list(path)
        case "read":
            if let continuation = args["continuation"] {
                guard let token = continuation as? String, args["offset"] == nil,
                      args["limit"] == nil else { throw AskFileRead.restart }
                return try readPage(path, continuation: token).rendered
            }
            func integer(_ key: String, fallback: Int) throws -> Int {
                guard let value = args[key] else { return fallback }
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= 0,
                      number.doubleValue <= Double(Self.maximumPagingValue) else { throw AskFileRead.restart }
                return number.intValue
            }
            return try read(
                path,
                offset: integer("offset", fallback: 0),
                limit: integer("limit", fallback: Self.maximumPagingValue)
            )
        case "search":
            guard let pattern = args["pattern"] as? String else { throw AskFileAccess.error(L("ask.tool.invalid")) }
            return try search(path, pattern: pattern)
        case "write":
            guard let content = args["content"] as? String else { throw AskFileAccess.error(L("ask.tool.invalid")) }
            return try write(path, content: content, expectedVersion: args["expected_version"] as? String)
        case "edit":
            guard let old = args["old_text"] as? String,
                  let new = args["new_text"] as? String else { throw AskFileAccess.error(L("ask.tool.invalid")) }
            return try edit(path, old: old, new: new, expectedVersion: args["expected_version"] as? String)
        default: throw AskFileAccess.error(L("ask.tool.invalid"))
        }
    }

    func read(_ path: String, offset: Int, limit: Int?) throws -> String {
        try readPage(path, offset: offset, limit: limit).rendered
    }

    func readPage(_ path: String, offset: Int = 0, limit: Int? = nil, continuation: String? = nil) throws -> AskFileRead
        .Page {
        let access = try AskFileAccess(AskFileAccess.location(path, roots: roots), hooks: hooks)
        return try AskFileRead.page(access, offset: offset, limit: limit, continuation: continuation)
    }

    func write(_ path: String, content: String, expectedVersion: String? = nil) throws -> String {
        try mutate(path, expectedVersion: expectedVersion, content: content, replacement: nil)
    }

    func edit(_ path: String, old: String, new: String, expectedVersion: String? = nil) throws -> String {
        try mutate(path, expectedVersion: expectedVersion, content: nil, replacement: (old, new))
    }
}
