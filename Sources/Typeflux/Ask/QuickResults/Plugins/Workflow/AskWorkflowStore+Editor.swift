import Foundation

/// What the workflow editor does to the workflows folder: save a draft under the
/// trust rules of `docs/design/ask-workflow-editor.md` §6.2, create, duplicate, and
/// install a workflow the assistant generated.
extension AskWorkflowStore {
    enum SaveOutcome: Equatable {
        /// Written. `trusted` tells whether the trust the loaded version had carried over.
        case saved(hash: String, trusted: Bool)
        /// The folder changed outside the editor since it was loaded; nothing was written.
        case conflict(currentHash: String)
    }

    enum EditorError: LocalizedError, Equatable {
        case pathOutside(String)
        case duplicateID(String)
        case invalidID
        case keyword(String)

        var errorDescription: String? {
            switch self {
            case let .pathOutside(path): L("ask.workflow.editor.error.pathOutside", path)
            case let .duplicateID(id): L("ask.workflow.editor.error.duplicateID", id)
            case .invalidID: L("ask.workflow.problem.id")
            case let .keyword(message): message
            }
        }
    }

    /// Writes a draft's changes. With `expectedHash` the write happens only when the
    /// folder is still what the editor loaded, and the new contents are trusted only
    /// when that loaded version was: the user's own edits never need confirming again,
    /// and nothing changed outside the editor is trusted along with them. Without it
    /// (the user chose to keep their version over an outside change) the write
    /// happens, but trust is never granted.
    func save(_ id: String, folder: URL, writes: [String: Data], deletes: [String] = [],
              expectedHash: String?) throws -> SaveOutcome {
        let current = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        if let expectedHash, current != expectedHash {
            return .conflict(currentHash: current)
        }
        let carriesTrust = expectedHash != nil && settings.askWorkflowTrust[id] == current
        try Self.write(writes, deletes: deletes, in: folder, fileManager: fileManager)
        let hash = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        let newID = Self.manifestID(in: folder) ?? id
        if newID != id {
            // A renamed workflow keeps its switch; its old trust entry goes.
            settings.askWorkflowTrust[id] = nil
            if let baseline = settings.askWorkflowGalleryBaseline.removeValue(forKey: id) {
                settings.askWorkflowGalleryBaseline[newID] = baseline
            }
            if let hosts = settings.askWorkflowAllowedHosts.removeValue(forKey: id) {
                settings.askWorkflowAllowedHosts[newID] = hosts
            }
            if settings.askDisabledWorkflows.remove(id) != nil {
                settings.askDisabledWorkflows.insert(newID)
            }
        }
        if carriesTrust {
            settings.askWorkflowTrust[newID] = hash
        }
        reload()
        return .saved(hash: hash, trusted: carriesTrust)
    }

    /// Writes files atomically inside `folder`, keeping each file's permissions. New
    /// files that start with `#!` or are one of the manifest's entry scripts become executable.
    nonisolated static func write(_ writes: [String: Data], deletes: [String], in folder: URL,
                                  fileManager: FileManager) throws {
        let paths = Array(writes.keys) + deletes
        for path in paths where AskWorkflowManifest.scriptURL(path, in: folder, fileManager: fileManager) == nil {
            throw EditorError.pathOutside(path)
        }
        let manifestData = writes[AskWorkflowManifest.fileName]
            ?? (try? Data(contentsOf: folder.appendingPathComponent(AskWorkflowManifest.fileName)))
        let entries = Set(manifestData.flatMap { try? JSONDecoder().decode(AskWorkflowManifest.self, from: $0) }?
            .entryScripts ?? [])
        for (path, data) in writes.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber
            try data.write(to: url, options: .atomic)
            let executable = entries.contains(path) || data.starts(with: Data("#!".utf8))
            let permissions = existing?.intValue ?? (executable ? 0o755 : 0o644)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        for path in deletes {
            let url = folder.appendingPathComponent(path)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - New workflows

    /// `local.` and the name in Latin letters (Chinese becomes pinyin), unique in the folder.
    func suggestedID(for name: String, fallback: String = "workflow") -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let slug = latin.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let base = "local." + String((slug.isEmpty ? fallback : slug).prefix(60))
        var id = base
        var number = 2
        while fileManager.fileExists(atPath: root.appendingPathComponent(id).path) || workflow(id) != nil {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    /// Why a keyword cannot be used, or nil: the same rules and namespace the launcher
    /// uses, against built-in keywords and every other workflow's.
    func keywordProblem(_ keyword: String, builtIn: [AskKeyword], excluding workflowID: String? = nil) -> String? {
        let others = builtIn + workflows.filter { $0.id != workflowID }.flatMap { workflow in
            (workflow.manifest?.keywords ?? []).map {
                AskKeyword(keyword: $0.keyword, pluginID: AskWorkflowPlugin.idPrefix + workflow.id)
            }
        }
        guard let problem = AskKeywordMatcher.problem(with: keyword, among: others) else { return nil }
        let word = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        // Say who has it: a built-in plugin or another workflow.
        guard problem == .duplicate, let owner = others.first(where: { $0.contains(word) }),
              let name = ownerName(owner.pluginID) else { return AskKeywordList.message(for: problem) }
        return L("ask.workflow.editor.keywordTakenBy", keyword, name)
    }

    /// The display name of what owns a keyword: a built-in plugin or a workflow.
    func ownerName(_ pluginID: String) -> String? {
        switch pluginID {
        case AskTranslatePlugin.id: return L("ask.plugin.translate.title")
        case AskPromptPlugin.id: return L("ask.plugin.prompt.title")
        case AskWebSearchPlugin.id: return L("ask.plugin.web.title")
        case AskFileSearchPlugin.id: return L("ask.plugin.files.title")
        case AskPrefixPlugin.id: return L("ask.plugin.prefix.title")
        case AskSettingsPlugin.id: return L("ask.plugin.setting.title")
        case AskHistoryPlugin.id: return L("ask.plugin.history.title")
        case AskClipboardPlugin.id: return L("ask.plugin.clip.title")
        case AskNotesPlugin.id: return L("ask.notes.title")
        case AskBrowserSearchPlugin.tabsID: return L("ask.browser.tabs")
        case AskBrowserSearchPlugin.bookmarksID: return L("ask.browser.bookmarks")
        default:
            guard pluginID.hasPrefix(AskWorkflowPlugin.idPrefix) else { return nil }
            let id = String(pluginID.dropFirst(AskWorkflowPlugin.idPrefix.count))
            return workflow(id).map { $0.manifest?.name ?? $0.id }
        }
    }

    /// Creates a workflow from a template with the name, keyword and id the user chose.
    /// It is trusted: the user made it here.
    @discardableResult
    func create(_ template: AskWorkflowTemplate, name: String, keyword: String, id: String,
                builtIn: [AskKeyword]) throws -> AskWorkflow {
        guard AskWorkflowManifest.isValidID(id) else { throw EditorError.invalidID }
        if let problem = keywordProblem(keyword, builtIn: builtIn) {
            throw EditorError.keyword(problem)
        }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard !fileManager.fileExists(atPath: folder.path),
              workflow(id) == nil else { throw EditorError.duplicateID(id) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest = template.manifest(id: id, keyword: keyword)
        manifest.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? template.title : name
        var writes = try [AskWorkflowManifest.fileName: Self.encode(manifest)]
        if let script = manifest.command.script {
            writes[script] = Data(template.script.utf8)
        }
        try Self.write(writes, deletes: [], in: folder, fileManager: fileManager)
        settings.askWorkflowTrust[id] = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        reload()
        return workflow(id) ?? AskWorkflow.load(folder: folder, trusted: nil, disabled: false, fileManager: fileManager)
    }

    /// Copies a workflow under a new id, name and keyword. The copy is trusted only
    /// when the original was trusted as it is now.
    @discardableResult
    func duplicate(_ sourceID: String, name: String, keyword: String, id: String,
                   builtIn: [AskKeyword]) throws -> AskWorkflow {
        guard let source = workflow(sourceID) else { throw EditorError.duplicateID(sourceID) }
        guard AskWorkflowManifest.isValidID(id) else { throw EditorError.invalidID }
        if let problem = keywordProblem(keyword, builtIn: builtIn) {
            throw EditorError.keyword(problem)
        }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard !fileManager.fileExists(atPath: folder.path),
              workflow(id) == nil else { throw EditorError.duplicateID(id) }
        let trusted = source.status == .ready || (source.status == .disabled
            && settings.askWorkflowTrust[sourceID] == source.hash)
        try fileManager.copyItem(at: source.folder, to: folder)
        var draft = AskWorkflowDraft.load(folder: folder, fileManager: fileManager)
        draft.set(id, at: ["id"])
        draft.set(name, at: ["name"])
        draft.set([["keyword": keyword]], at: ["keywords"])
        // A copy is the user's own workflow, not the gallery example the original was added from.
        draft.set(nil, at: ["origin"])
        try Self.write([AskWorkflowManifest.fileName: Data(draft.manifestText.utf8)], deletes: [], in: folder,
                       fileManager: fileManager)
        if trusted {
            settings.askWorkflowTrust[id] = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        }
        reload()
        return workflow(id) ?? AskWorkflow.load(folder: folder, trusted: nil, disabled: false, fileManager: fileManager)
    }

    /// Moves a workflow the assistant generated from its staging folder into the
    /// workflows folder and trusts it: the user read the proposal and chose to save it.
    @discardableResult
    func install(from staging: URL) throws -> AskWorkflow {
        guard let id = Self.manifestID(in: staging),
              AskWorkflowManifest.isValidID(id) else { throw EditorError.invalidID }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(id, isDirectory: true)
        guard !fileManager.fileExists(atPath: folder.path),
              workflow(id) == nil else { throw EditorError.duplicateID(id) }
        try fileManager.moveItem(at: staging, to: folder)
        settings.askWorkflowTrust[id] = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        reload()
        return workflow(id) ?? AskWorkflow.load(folder: folder, trusted: nil, disabled: false, fileManager: fileManager)
    }

    nonisolated static func encode(_ manifest: AskWorkflowManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }
}
