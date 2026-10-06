import CryptoKit
import Foundation

/// Adding gallery examples to the workflows folder and updating them (§1.3): a copy
/// the user owns, trusted because it ships with the app, renamed where it clashes,
/// and never overwritten without the user looking at the differences first.
extension AskWorkflowStore {
    /// What adding an example did: the new workflow, and the keywords it had to rename.
    struct GalleryAddition: Equatable {
        var workflow: AskWorkflow
        /// Original keyword → the one used instead.
        var renamed: [String: String]
    }

    /// What updating an example would change: the installed files and the new version's,
    /// and which files the user changed since adding it.
    struct GalleryUpdate: Equatable {
        var workflowID: String
        var current: AskWorkflowDraft
        var updated: AskWorkflowDraft
        var userModified: Set<String>
    }

    /// The workflow added from `item`, if the user still has it.
    func installed(_ item: AskWorkflowGallery.Item) -> AskWorkflow? {
        workflows.first { $0.manifest?.origin?.gallery == item.id }
    }

    /// The example has a newer version than the one the user added.
    func hasUpdate(_ item: AskWorkflowGallery.Item) -> Bool {
        guard let version = installed(item)?.manifest?.origin?.version else { return false }
        return AskWorkflowGallery.isOlder(version, than: item.version)
    }

    /// Copies an example into the workflows folder as `local.<id>` (`-2`, `-3`… when
    /// taken), renaming keywords that clash with built-in ones or other workflows'
    /// (`fx` → `fx2`). It is trusted: it ships with the app.
    @discardableResult
    func add(_ item: AskWorkflowGallery.Item, builtIn: [AskKeyword]) throws -> GalleryAddition {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = AskWorkflowManifest.isValidID(item.manifest.id) ? item.manifest.id : "local." + item.id
        var id = base
        var number = 2
        while fileManager.fileExists(atPath: root.appendingPathComponent(id).path) || workflow(id) != nil {
            id = "\(base)-\(number)"
            number += 1
        }
        var renamed: [String: String] = [:]
        var chosen: [AskKeyword] = []
        let keywords = item.keywords.map { original -> String in
            var keyword = original
            var suffix = 2
            while keywordProblem(keyword, builtIn: builtIn + chosen) != nil, suffix < 100 {
                keyword = original + String(suffix)
                suffix += 1
            }
            if keyword != original {
                renamed[original] = keyword
            }
            chosen.append(AskKeyword(keyword: keyword, pluginID: AskWorkflowPlugin.idPrefix + id))
            return keyword
        }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = AskWorkflowGallery.render(item, id: id, keywords: keywords, fileManager: fileManager)
        do {
            try Self.write(files, deletes: [], in: folder, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        settings.askWorkflowTrust[id] = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        settings.askWorkflowGalleryBaseline[id] = Self.fileHashes(files)
        reload()
        let added = workflow(id) ?? AskWorkflow.load(
            folder: folder,
            trusted: nil,
            disabled: false,
            fileManager: fileManager
        )
        return GalleryAddition(workflow: added, renamed: renamed)
    }

    /// The new version of an added example next to the user's files. The new version
    /// keeps the workflow's id and the keywords the user has, so only what the
    /// example changed shows up as a difference.
    func galleryUpdate(_ item: AskWorkflowGallery.Item) -> GalleryUpdate? {
        guard let workflow = installed(item), let manifest = workflow.manifest else { return nil }
        let current = AskWorkflowDraft.load(folder: workflow.folder, fileManager: fileManager)
        let files = renderUpdate(item, workflow: workflow, manifest: manifest)
        var updated = current
        for (path, data) in files {
            updated.setText(String(bytes: data, encoding: .utf8) ?? "", of: path)
        }
        for path in removedByUpdate(workflow.id, files: files) {
            updated.files[path] = nil
        }
        let baseline = settings.askWorkflowGalleryBaseline[workflow.id] ?? [:]
        var modified = Set<String>()
        for path in current.paths {
            guard let text = current.text(of: path) else { continue }
            if let hash = baseline[path], hash != Self.hash(Data(text.utf8)) {
                modified.insert(path)
            }
        }
        return GalleryUpdate(workflowID: workflow.id, current: current, updated: updated, userModified: modified)
    }

    /// Overwrites an added example with the new version, after the user looked at the
    /// differences. Files the old version had and the new one does not are removed;
    /// files the user added stay. It stays trusted.
    @discardableResult
    func applyUpdate(_ item: AskWorkflowGallery.Item) throws -> AskWorkflow? {
        guard let workflow = installed(item), let manifest = workflow.manifest else { return nil }
        let files = renderUpdate(item, workflow: workflow, manifest: manifest)
        try Self.write(files, deletes: removedByUpdate(workflow.id, files: files), in: workflow.folder,
                       fileManager: fileManager)
        settings.askWorkflowTrust[workflow.id] = AskWorkflow.contentHash(of: workflow.folder, fileManager: fileManager)
        settings.askWorkflowGalleryBaseline[workflow.id] = Self.fileHashes(files)
        reload()
        return self.workflow(workflow.id)
    }

    private func renderUpdate(_ item: AskWorkflowGallery.Item, workflow: AskWorkflow,
                              manifest: AskWorkflowManifest) -> [String: Data] {
        // Keywords carry over by position when the example still has as many.
        let keywords = manifest.keywords.count == item.keywords.count ? manifest.keywords.map(\.keyword) : item.keywords
        return AskWorkflowGallery.render(item, id: workflow.id, keywords: keywords, fileManager: fileManager)
    }

    /// Files the added version had that the new one does not.
    private func removedByUpdate(_ id: String, files: [String: Data]) -> [String] {
        let baseline = settings.askWorkflowGalleryBaseline[id] ?? [:]
        return baseline.keys.filter { files[$0] == nil && $0 != AskWorkflowManifest.fileName }.sorted()
    }

    nonisolated static func fileHashes(_ files: [String: Data]) -> [String: String] {
        files.mapValues(hash)
    }

    nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension SettingsStore {
    /// For each workflow added from the gallery, the hash of every file as it was added
    /// or last updated, by path: tells which files the user changed since.
    var askWorkflowGalleryBaseline: [String: [String: String]] {
        get { (defaults.dictionary(forKey: "ask.workflows.galleryBaseline") as? [String: [String: String]]) ?? [:] }
        set { defaults.set(newValue, forKey: "ask.workflows.galleryBaseline") }
    }
}
