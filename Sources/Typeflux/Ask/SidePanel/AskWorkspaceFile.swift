import Foundation

/// One file in a conversation's workspace, as the side panel's Files tab lists it.
struct AskWorkspaceFile: Identifiable, Equatable, Sendable {
    /// Where the file came from, decided by the workspace folder holding it.
    enum Origin: String, CaseIterable, Sendable {
        /// `inputs/`: files the user sent or added.
        case upload
        /// `outputs/`: files the AI produced.
        case generated
        /// `work/`: intermediate files from the AI's work.
        case process

        static func folder(_ name: String) -> Origin? {
            switch name {
            case "inputs": .upload
            case "outputs": .generated
            case "work": .process
            default: nil
            }
        }
    }

    /// Path inside the workspace, such as `outputs/report.html`.
    let relativePath: String
    let size: Int64
    let modifiedAt: Date
    let origin: Origin
    /// The message the file was recorded with, when `.typeflux/files.json` knows it.
    let messageId: String?

    var id: String { relativePath }

    /// The stored name without the uniqueness prefixes the workspace adds.
    var name: String { Self.displayName(relativePath) }

    var pathExtension: String { (relativePath as NSString).pathExtension.lowercased() }

    private static let prefixes = [
        // inputs/<message digest>-<source digest>-name
        #"^[0-9a-f]{16}-[0-9a-f]{16}-(.+)$"#,
        // inputs/<message digest>-screenshot.jpg
        #"^[0-9a-f]{16}-(screenshot\.jpg)$"#,
        // outputs/<uuid>-name
        #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-(.+)$"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func displayName(_ relativePath: String) -> String {
        let name = (relativePath as NSString).lastPathComponent
        guard ["inputs", "outputs"].contains(relativePath.split(separator: "/").first.map(String.init)) else {
            return name
        }
        let range = NSRange(name.startIndex..., in: name)
        for expression in prefixes {
            if let match = expression.firstMatch(in: name, range: range),
               let captured = Range(match.range(at: 1), in: name) {
                return String(name[captured])
            }
        }
        return name
    }
}

/// Filtering, searching, grouping and ordering for the Files tab.
struct AskWorkspaceFileQuery: Equatable {
    /// Files recorded with one message; a nil message collects the rest.
    struct Group: Equatable, Identifiable {
        let messageId: String?
        let files: [AskWorkspaceFile]
        var id: String { messageId ?? "" }
    }

    /// Nil shows every origin.
    var origin: AskWorkspaceFile.Origin?
    var search = ""

    func matches(_ file: AskWorkspaceFile) -> Bool {
        if let origin, file.origin != origin { return false }
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return file.name.localizedCaseInsensitiveContains(text)
    }

    /// Newest first; equal dates fall back to the name so the order is stable.
    static func sorted(_ files: [AskWorkspaceFile]) -> [AskWorkspaceFile] {
        files.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.relativePath < $1.relativePath : byName == .orderedAscending
        }
    }

    /// Matching files grouped by message. Groups follow `messageOrder` (the conversation's
    /// message ids, oldest first) newest message first; unknown messages follow by their newest
    /// file, and files without a message come last.
    func groups(_ files: [AskWorkspaceFile], messageOrder: [String] = []) -> [Group] {
        let matching = Self.sorted(files.filter(matches))
        var byMessage: [String: [AskWorkspaceFile]] = [:]
        var unassigned: [AskWorkspaceFile] = []
        for file in matching {
            if let id = file.messageId { byMessage[id, default: []].append(file) } else { unassigned.append(file) }
        }
        let position = Dictionary(messageOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = byMessage.keys.sorted { lhs, rhs in
            switch (position[lhs], position[rhs]) {
            case let (left?, right?): return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                let left = byMessage[lhs]?.first?.modifiedAt ?? .distantPast
                let right = byMessage[rhs]?.first?.modifiedAt ?? .distantPast
                return left == right ? lhs < rhs : left > right
            }
        }
        var groups = ordered.map { Group(messageId: $0, files: byMessage[$0] ?? []) }
        if !unassigned.isEmpty { groups.append(Group(messageId: nil, files: unassigned)) }
        return groups
    }

    /// How many files each origin filter would show, for the filter's counts.
    static func counts(_ files: [AskWorkspaceFile]) -> [AskWorkspaceFile.Origin: Int] {
        Dictionary(grouping: files, by: \.origin).mapValues(\.count)
    }
}
