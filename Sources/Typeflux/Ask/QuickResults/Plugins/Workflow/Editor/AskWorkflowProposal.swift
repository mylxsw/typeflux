import Foundation

/// A change the assistant offers: a whole manifest and the files to write or
/// remove. It never touches the user's files; applying it changes the editor's
/// draft, which is saved like any edit. See `docs/design/ask-workflow-editor.md` §10.3.
struct AskWorkflowProposal: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable { case pending, applied, discarded }

    static let maximumFiles = 20
    static let maximumFileSize = 256_000

    var id = UUID()
    var summary: String
    /// The new `workflow.json`; nil leaves it as it is.
    var manifestText: String?
    /// Files to write, by path relative to the workflow folder.
    var files: [String: String]
    var deletes: [String]
    var risks: Set<AskWorkflowRisk> = []
    /// Risks the version it changes did not have.
    var newRisks: Set<AskWorkflowRisk> = []
    /// Test runs of this proposal, latest last.
    var tests: [AskWorkflowTestResult] = []
    var state: State = .pending

    /// The draft as it would be with this proposal applied.
    func applied(to base: AskWorkflowDraft) -> AskWorkflowDraft {
        var draft = base
        if let manifestText {
            draft.manifestText = manifestText
        }
        for (path, text) in files {
            draft.files[path] = text
        }
        for path in deletes {
            draft.files[path] = nil
        }
        return draft
    }

    /// Paths the proposal changes against `base`, with lines added and removed.
    func changes(against base: AskWorkflowDraft) -> [AskWorkflowDiff.FileChange] {
        let result = applied(to: base)
        return result.paths.compactMap { path -> AskWorkflowDiff.FileChange? in
            let old = base.text(of: path) ?? ""
            let new = result.text(of: path) ?? ""
            guard old != new || base.text(of: path) == nil else { return nil }
            return AskWorkflowDiff.change(path: path, old: old, new: new)
        } + deletes.filter { base.files[$0] != nil }.map {
            AskWorkflowDiff.change(path: $0, old: base.files[$0] ?? "", new: "")
        }
    }

    /// Why the files cannot be accepted, or nil: paths stay inside the folder, the
    /// manifest is written through `manifestText`, and sizes are bounded.
    static func problem(files: [String: String], deletes: [String]) -> String? {
        if files.count > maximumFiles {
            return L("ask.workflow.assistant.problem.tooManyFiles", maximumFiles)
        }
        for path in Array(files.keys) + deletes {
            let parts = path.split(separator: "/")
            if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") || parts.contains("..") || parts.contains(".")
                || path.contains("\\") || parts.contains(where: { $0.hasPrefix(".") }) {
                return L("ask.workflow.editor.error.pathOutside", path)
            }
            if path == AskWorkflowManifest.fileName {
                return L("ask.workflow.assistant.problem.manifestFile")
            }
        }
        if let large = files.first(where: { $0.value.utf8.count > maximumFileSize }) {
            return L("ask.workflow.assistant.problem.tooLarge", large.key)
        }
        return nil
    }
}

/// Line differences for proposal and outside-change views.
enum AskWorkflowDiff {
    enum Kind: Equatable, Sendable { case same, added, removed }

    struct Line: Equatable, Sendable {
        var kind: Kind
        var text: String
        /// 1-based line number in the new text; in the old text for removed lines.
        var number: Int
    }

    struct FileChange: Equatable, Sendable {
        var path: String
        var added: Int
        var removed: Int
        var isNew: Bool
        var isDeleted: Bool
    }

    /// Old and new text merged line by line.
    static func lines(old: String, new: String) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removed.contains(oldIndex) {
                result.append(Line(kind: .removed, text: before[oldIndex], number: oldIndex + 1))
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                result.append(Line(kind: .added, text: after[newIndex], number: newIndex + 1))
                newIndex += 1
            } else if oldIndex < before.count, newIndex < after.count {
                result.append(Line(kind: .same, text: after[newIndex], number: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        return result
    }

    static func change(path: String, old: String, new: String) -> FileChange {
        let lines = lines(old: old, new: new)
        return FileChange(path: path, added: lines.filter { $0.kind == .added }.count,
                          removed: lines.filter { $0.kind == .removed }.count,
                          isNew: old.isEmpty && !new.isEmpty, isDeleted: !old.isEmpty && new.isEmpty)
    }
}

/// Throwaway folders where the assistant's proposals are written and test-run,
/// and where a generated workflow waits until the user saves it.
struct AskWorkflowStaging: Sendable {
    var root: URL

    static func defaultRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/Typeflux/WorkflowDrafts", isDirectory: true)
    }

    init(root: URL = AskWorkflowStaging.defaultRoot()) {
        self.root = root
    }

    /// A new folder holding `draft`: the files of `source` (icons and other files the
    /// draft does not open) with the draft's text on top.
    func make(_ draft: AskWorkflowDraft, copying source: URL? = nil,
              fileManager: FileManager = .default) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let source, fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: folder)
            for path in draft.savedPaths where draft.files[path] == nil {
                try? fileManager.removeItem(at: folder.appendingPathComponent(path))
            }
        } else {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var writes = [AskWorkflowManifest.fileName: Data(draft.manifestText.utf8)]
        for (path, text) in draft.files {
            writes[path] = Data(text.utf8)
        }
        try AskWorkflowStore.write(writes, deletes: [], in: folder, fileManager: fileManager)
        return folder
    }

    func remove(_ folder: URL, fileManager: FileManager = .default) {
        guard folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? fileManager.removeItem(at: folder)
    }

    /// Removes staging folders older than `age`, left by a quit or a crash.
    func prune(olderThan age: TimeInterval = 86400, now: Date = Date(), fileManager: FileManager = .default) {
        let folders = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: folder)
            }
        }
    }
}
