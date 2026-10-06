import Foundation

/// What the editor's toolbar, status bar, test panel and banners show, worked out
/// from the model so the views stay simple (and testable).
extension AskWorkflowEditorModel {
    /// One row of "Recent runs": a test run from this editor or a launcher run.
    struct HistoryItem: Identifiable, Equatable {
        var id: String
        var succeeded: Bool
        var title: String
        var duration: Double
        var date: Date
    }

    /// Lines added and removed by an outside change, and the files it touched.
    struct OutsideStats: Equatable {
        var added: Int
        var removed: Int
        var paths: [String]
    }

    /// "main.py unsaved", "Configuration unsaved", or nil when nothing is.
    var unsavedLabel: String? {
        guard let draft, draft.isDirty else { return nil }
        let changed = draft.changedPaths + draft.deletedPaths
        guard changed.count == 1, let path = changed.first else {
            return L("ask.workflow.editor.unsavedFiles", changed.count)
        }
        let name = path == AskWorkflowManifest.fileName ? L("ask.workflow.editor.config") : path
        return L("ask.workflow.editor.unsavedFile", name)
    }

    /// The latest runs, test runs from this editor (with what was typed) and launcher
    /// runs from the log (which keeps no input), newest first.
    var history: [HistoryItem] {
        var items = results.enumerated().map { index, result in
            HistoryItem(id: "test-\(index)", succeeded: result.succeeded,
                        title: L("ask.workflow.editor.test.sourceTest",
                                 result.input.query.isEmpty ? "—" : result.input.query),
                        duration: result.duration, date: result.date)
        }
        if let id = workflowID {
            let launcher = (AskWorkflowLog.shared.entries[id] ?? []).filter { $0.source == .launcher }
            items += launcher.enumerated().map { index, entry in
                HistoryItem(id: "launcher-\(index)", succeeded: entry.exitCode == 0 && !entry.timedOut,
                            title: L("ask.workflow.editor.test.sourceLauncher", entry.keyword),
                            duration: entry.duration, date: entry.date)
            }
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(5))
    }

    /// "just now", "2 minutes ago", for the history and the outside-change banner.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 {
            return L("ask.workflow.editor.justNow")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.shared.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// What the outside change did, for its banner and the status bar.
    var outsideStats: OutsideStats? {
        guard let change = outsideChange, let draft else { return nil }
        let paths = Set(draft.paths + change.disk.paths).sorted()
            .filter { draft.text(of: $0) != change.disk.text(of: $0) }
        var added = 0, removed = 0
        for path in paths {
            let diff = AskWorkflowDiff.change(
                path: path,
                old: draft.text(of: path) ?? "",
                new: change.disk.text(of: path) ?? ""
            )
            added += diff.added
            removed += diff.removed
        }
        return OutsideStats(added: added, removed: removed, paths: paths)
    }

    /// "3f9a…c21e": the hash the user last trusted, for the status bar.
    var trustedHashLabel: String? {
        guard let id = workflowID, let hash = settings.askWorkflowTrust[id], hash.count > 8 else { return nil }
        return hash.prefix(4) + "…" + hash.suffix(4)
    }

    /// The 1-based number of a proposal in this conversation, for "Run proposal 2?".
    func proposalNumber(_ id: UUID) -> Int {
        (proposals.firstIndex { $0.id == id } ?? 0) + 1
    }

    /// Shows a manifest problem on its line of `workflow.json`.
    func revealProblem(_ problem: AskWorkflowManifest.Problem) {
        // Any step but the script shows the configuration, here as JSON.
        let target = AskWorkflowDraft.step(for: problem.field) ?? .keywords
        step = target == .script ? .output : target
        configMode = .json
        if let line = draft?.line(for: problem.field) {
            reveal = (AskWorkflowManifest.fileName, line)
        }
    }

    // MARK: - Quick fixes

    /// A file that exists for a manifest whose script does not: same extension first,
    /// then any file the runtime can run.
    var scriptSuggestion: String? {
        guard let draft, let manifest = draft.manifest, let script = manifest.command.script,
              draft.files[script] == nil,
              !store.fileManager.fileExists(atPath: draft.folder.appendingPathComponent(script).path)
        else { return nil }
        let candidates = draft.files.keys.sorted().filter { !$0.lowercased().hasSuffix(".md") }
        let wanted = (script as NSString).pathExtension.lowercased()
        let language = AskWorkflowSyntaxHighlighter.Language.detect(path: script, runtime: manifest.command.runtime)
        return candidates.first { ($0 as NSString).pathExtension.lowercased() == wanted }
            ?? candidates.first {
                AskWorkflowSyntaxHighlighter.Language.detect(path: $0, runtime: manifest.command.runtime) == language
            }
    }

    func applyScriptSuggestion() {
        guard let suggestion = scriptSuggestion else { return }
        set(suggestion, at: ["command", "script"])
    }

    // MARK: - Runtime

    /// Looks up the runtime's interpreter and version once per open workflow.
    func refreshRuntimeInfo() {
        runtimeInfo = nil
        guard let command = draft?.manifest?.command else { return }
        let probe = runtimeProbe
        let name = command.interpreter ?? command.runtime.interpreterName
        let title = command.runtime.title
        Task { [weak self] in
            let report = await probe.report(commands: name.map { [$0] } ?? [])
            guard let self, draft?.manifest?.command == command else { return }
            runtimeInfo = Self.runtimeDescription(report, name: name, title: title)
        }
    }

    /// The interpreter's version and path from an environment report, or the runtime's name.
    static func runtimeDescription(_ report: String, name: String?, title: String) -> String {
        guard let name, let data = report.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return title }
        if let known = (object["runtimes"] as? [String: Any])?[name] as? String {
            return known
        }
        if let path = (object["commands"] as? [String: Any])?[name] as? String {
            return title + " · " + path
        }
        return L("ask.workflow.missingRuntime", name)
    }
}

/// How a file indents, shared by the code view (Tab inserts that much) and the status bar.
enum AskWorkflowCodeIndentation {
    /// Two spaces when the file mostly indents by two, else four.
    static func width(of text: String) -> Int {
        let indents = text.components(separatedBy: "\n").compactMap { line -> Int? in
            let count = line.prefix { $0 == " " }.count
            return count > 0 ? count : nil
        }
        guard let smallest = indents.min() else { return 4 }
        return smallest == 2 ? 2 : 4
    }
}
