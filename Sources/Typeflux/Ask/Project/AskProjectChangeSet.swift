import Foundation

/// Persisted locally, never a replacement for approval or source validation.
struct AskProjectChangeSet: Codable {
    struct Entry: Codable, Equatable {
        var path: String
        var sourceVersion: String
        var original: Data?
        var updated: Data

        var version: String {
            AskToolPolicy.digest(sourceVersion + ":" + AskToolPolicy.digest(updated))
        }
    }

    var workspace: AskWorkspaceRef
    var root: String
    var rootIdentity: String
    var entries: [Entry] = []

    /// Whole-file unified hunks favor an auditable bounded implementation. They
    /// apply to the captured working copy, including any pre-existing dirty text.
    var patch: String {
        entries.sorted { $0.path < $1.path }.map(Self.patch).joined()
    }

    private static func quoted(_ path: String) -> String {
        // Git's C-quoted paths preserve spaces, quotes and non-ASCII UTF-8 bytes.
        "\"" + path.utf8.map { byte -> String in
            if byte == 34 {
                return "\\\""
            }
            if byte == 92 {
                return "\\\\"
            }
            if byte < 32 || byte >= 127 {
                return String(format: "\\%03o", byte)
            }
            return String(UnicodeScalar(byte))
        }.joined() + "\""
    }

    static func patch(_ entry: Entry) -> String {
        guard entry.original != entry.updated else { return "" }
        // Entries are validated UTF-8 when staged and when loaded from disk.
        let old = String(data: entry.original ?? Data(), encoding: .utf8) ?? ""
        let new = String(data: entry.updated, encoding: .utf8) ?? ""
        func lines(_ value: String) -> [String] {
            guard !value.isEmpty else { return [] }
            var parts = value.components(separatedBy: "\n")
            if value.hasSuffix("\n") {
                parts.removeLast()
            }
            return parts
        }
        let removed = lines(old), added = lines(new)
        let oldPath = quoted("a/" + entry.path), newPath = quoted("b/" + entry.path)
        var output = "diff --git \(oldPath) \(newPath)\n"
        if entry.original == nil {
            output += "new file mode 100644\n"
        }
        output += "--- \(entry.original == nil ? "/dev/null" : oldPath)\n+++ \(newPath)\n"
        // An empty new file needs only its extended header.
        if removed.isEmpty, added.isEmpty {
            return output
        }
        output += "@@ -\(removed.isEmpty ? 0 : 1),\(removed.count) +\(added.isEmpty ? 0 : 1),\(added.count) @@\n"
        for (index, line) in removed.enumerated() {
            output += "-" + line + "\n"
            if index == removed.count - 1, !old.hasSuffix("\n") {
                output += "\\ No newline at end of file\n"
            }
        }
        for (index, line) in added.enumerated() {
            output += "+" + line + "\n"
            if index == added.count - 1, !new.hasSuffix("\n") {
                output += "\\ No newline at end of file\n"
            }
        }
        return output
    }
}

struct AskProjectReview: Codable, Equatable {
    var kind = "project_review_v1"
    var workspace: AskWorkspaceRef
    var files: [String]
    var patch: String
    var patchHash: String
    var truncated: Bool

    init(changeSet: AskProjectChangeSet) {
        let full = changeSet.patch
        workspace = changeSet.workspace
        files = changeSet.entries.map(\.path).sorted()
        patch = AskProjectFileAccess.preview(full)
        patchHash = AskToolPolicy.digest(full)
        truncated = patch != full
    }

    static func decode(_ text: String) -> Self? {
        guard text.utf8.count <= 300_000, let review = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)),
              review.kind == "project_review_v1" else { return nil }
        return review
    }
}
