import Foundation

/// The files under a conversation's `outputs/` and `work/` at one moment: what a run's
/// "files changed" list is computed from. Taken before the run and again when it ends.
struct AskWorkspaceSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let size: Int64
        let modifiedAt: Date
        /// SHA-256 of the content, kept for files small enough to hash; it tells a file
        /// that was only touched from one whose content changed.
        let digest: String?
    }

    static let folders = ["outputs", "work"]
    /// Same bound as the Files tab, so a huge `work/` folder cannot stall a run's end.
    static let fileLimit = AskConversationWorkspaceStore.listedFileLimit
    static let digestFileLimit: Int64 = 8 * 1024 * 1024
    static let digestTotalLimit: Int64 = 128 * 1024 * 1024

    /// Keyed by the path inside the workspace, such as `outputs/report.html`.
    var entries: [String: Entry] = [:]

    /// Scans `outputs/` and `work/` without following links or listing hidden files. A
    /// workspace that does not exist yet is empty. Digests of files unchanged since
    /// `previous` (same size and time) are reused instead of reading them again.
    static func capture(root: URL, reusing previous: AskWorkspaceSnapshot? = nil) -> AskWorkspaceSnapshot {
        var snapshot = AskWorkspaceSnapshot()
        var hashed: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        for folder in folders {
            let base = root.appendingPathComponent(folder, isDirectory: true)
            guard let values = try? base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(
                      at: base, includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  ) else { continue }
            for case let url as URL in enumerator {
                guard snapshot.entries.count < fileLimit else { return snapshot }
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                // The enumerator's depth, not the base's components: enumerated URLs may come
                // back resolved (`/private/var` for `/var`).
                let relative = ([folder] + url.pathComponents.suffix(enumerator.level)).joined(separator: "/")
                let size = Int64(values.fileSize ?? 0)
                let modifiedAt = values.contentModificationDate ?? .distantPast
                var digest: String?
                if let old = previous?.entries[relative], old.size == size, old.modifiedAt == modifiedAt {
                    digest = old.digest
                } else if size <= digestFileLimit, hashed + size <= digestTotalLimit,
                          let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    hashed += size
                    digest = AskToolPolicy.digest(data)
                }
                snapshot.entries[relative] = Entry(size: size, modifiedAt: modifiedAt, digest: digest)
            }
        }
        return snapshot
    }

    /// Files added or modified between this snapshot and `after`, by path. Deleted files are
    /// left out. A file whose time changed but whose content is the same is not modified;
    /// without digests on both sides, a new time counts as a change.
    func changes(to after: AskWorkspaceSnapshot) -> [AskWorkspaceFileChange] {
        after.entries.keys.sorted().compactMap { path in
            guard let new = after.entries[path] else { return nil }
            guard let old = entries[path] else { return AskWorkspaceFileChange(path: path, kind: .added) }
            if old.size != new.size { return AskWorkspaceFileChange(path: path, kind: .modified) }
            if let oldDigest = old.digest, let newDigest = new.digest {
                return oldDigest == newDigest ? nil : AskWorkspaceFileChange(path: path, kind: .modified)
            }
            return old.modifiedAt == new.modifiedAt ? nil : AskWorkspaceFileChange(path: path, kind: .modified)
        }
    }
}

/// One file a run added or modified in the conversation's workspace.
struct AskWorkspaceFileChange: Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case added, modified
    }

    /// Path inside the workspace, such as `outputs/report.html`.
    let path: String
    let kind: Kind
    /// How the run's file tool changed it: whole-file writes and exact edits.
    var writes = 0
    var edits = 0

    var id: String { path }
    var name: String { AskWorkspaceFile.displayName(path) }
    /// `work/` holds the AI's intermediate files; they fold under one line.
    var isProcess: Bool { path.hasPrefix("work/") }

    /// A one-line note for a modified file, from the tool calls that changed it.
    var summary: String? {
        guard kind == .modified else { return nil }
        if writes > 0 { return L("ask.fileChanges.rewritten") }
        if edits > 0 { return L("ask.fileChanges.edited", edits) }
        return nil
    }

    /// Counts the run's `files` writes and edits per workspace path. Paths may be relative
    /// (`./work/a.py`) or absolute under `root`; others belong to granted folders and are skipped.
    static func toolCounts(_ calls: [AskToolCall], root: String) -> [String: (writes: Int, edits: Int)] {
        var counts: [String: (writes: Int, edits: Int)] = [:]
        for call in calls where call.function.name == "files" {
            guard let args = try? AskLocalTools.jsonArguments(call.function.arguments),
                  let action = args["action"] as? String, ["write", "edit"].contains(action),
                  let raw = args["path"] as? String, let path = workspacePath(raw, root: root) else { continue }
            var value = counts[path] ?? (0, 0)
            if action == "write" { value.writes += 1 } else { value.edits += 1 }
            counts[path] = value
        }
        return counts
    }

    /// `raw` as a path inside the workspace, or nil when it points elsewhere.
    static func workspacePath(_ raw: String, root: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix("/") {
            guard path.hasPrefix(prefix) else { return nil }
            path.removeFirst(prefix.count)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}
