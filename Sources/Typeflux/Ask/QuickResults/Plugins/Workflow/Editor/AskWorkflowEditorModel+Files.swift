import Foundation

/// Entry scripts and the Files card (§2.2, §2.3): which file each keyword runs and
/// what the other files are for.
extension AskWorkflowEditorModel {
    /// Files a keyword can run: scripts in the language of the workflow's runtime
    /// (any file for an executable), sorted by name. The default entry is not one:
    /// choosing it means "Default".
    var entryCandidates: [String] {
        guard let draft, let manifest = draft.manifest else { return [] }
        let language = AskWorkflowSyntaxHighlighter.Language.detect(path: "", runtime: manifest.command.runtime)
        return draft.files.keys.filter { path in
            path != manifest.command.script && (manifest.command.runtime == .exec
                || AskWorkflowSyntaxHighlighter.Language
                .detect(path: path, runtime: manifest.command.runtime) == language)
        }.sorted()
    }

    /// Sets (or with nil clears) the entry script of the keyword at `index`.
    func setKeywordScript(_ script: String?, at index: Int) {
        guard var rows = draft?.value(at: ["keywords"]) as? [[String: Any]],
              rows.indices.contains(index) else { return }
        let manifest = draft?.manifest
        rows[index]["script"] = script == nil || script == manifest?.command.script ? nil : script
        set(rows, at: ["keywords"])
    }

    /// The Files card's rows.
    var fileRows: [AskWorkflowFileReferences.Row] {
        guard let draft else { return [] }
        return AskWorkflowFileReferences.rows(manifest: draft.manifest, files: draft.files)
    }

    /// The entry scripts of the open workflow, for the marks on the file tabs.
    var entryScripts: Set<String> {
        Set(draft?.manifest?.entryScripts ?? [])
    }

    /// Shows a file in the Script step.
    func openFile(_ path: String) {
        guard draft?.files[path] != nil else { return }
        previewingProposal = nil
        showingDiff = false
        step = .script
        selectedFile = path
    }
}
