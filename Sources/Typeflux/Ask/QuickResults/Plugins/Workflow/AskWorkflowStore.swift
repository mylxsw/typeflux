import AppKit
import Foundation

/// The workflows in `~/Library/Application Support/Typeflux/Workflows/`: reads
/// them, remembers which ones the user trusted (by content hash) or switched off,
/// and creates new ones from templates.
@MainActor
final class AskWorkflowStore: ObservableObject {
    static let shared = AskWorkflowStore(settings: SettingsStore())

    let root: URL
    let home: String
    private let settings: SettingsStore
    private let fileManager: FileManager
    private let trash: (URL) throws -> Void
    @Published private(set) var workflows: [AskWorkflow] = []

    init(settings: SettingsStore, root: URL = AskWorkflow.root(), home: String = NSHomeDirectory(),
         fileManager: FileManager = .default,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.settings = settings
        self.root = root
        self.home = home
        self.fileManager = fileManager
        self.trash = trash
    }

    /// Reads every workflow folder again, in name order.
    func reload() {
        apply(Self.scan(root: root, trusted: settings.askWorkflowTrust, disabled: settings.askDisabledWorkflows,
                        fileManager: fileManager))
    }

    /// `reload()` with the reading and hashing off the main thread, for the launcher.
    func refresh() async {
        let root = root, trusted = settings.askWorkflowTrust, disabled = settings.askDisabledWorkflows
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, trusted: trusted, disabled: disabled, fileManager: .default)
        }.value
        apply(scanned)
    }

    private func apply(_ scanned: [AskWorkflow]) {
        if scanned != workflows { workflows = scanned }
    }

    nonisolated static func scan(root: URL, trusted: [String: String], disabled: Set<String>,
                                 fileManager: FileManager) -> [AskWorkflow] {
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])) ?? []
        var loaded = folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { folder -> AskWorkflow in
                let id = Self.manifestID(in: folder) ?? folder.lastPathComponent
                return AskWorkflow.load(folder: folder, trusted: trusted[id], disabled: disabled.contains(id),
                                        fileManager: fileManager)
            }
            .sorted { ($0.manifest?.name ?? $0.id).localizedStandardCompare($1.manifest?.name ?? $1.id) == .orderedAscending }
        // Two folders claiming one id: the first keeps it, the rest are flagged.
        var seen = Set<String>()
        for index in loaded.indices {
            if seen.contains(loaded[index].id), loaded[index].manifest != nil {
                loaded[index].status = .invalid([AskWorkflowManifest.Problem(field: "id",
                                                                            message: L("ask.workflow.problem.duplicateID"))])
            }
            seen.insert(loaded[index].id)
        }
        return loaded
    }

    private nonisolated static func manifestID(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(AskWorkflowManifest.fileName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["id"] as? String
    }

    func workflow(_ id: String) -> AskWorkflow? { workflows.first { $0.id == id } }

    // MARK: - Trust and switches

    /// Confirms the workflow as its files are now.
    func trust(_ id: String) {
        guard let workflow = workflow(id) else { return }
        settings.askWorkflowTrust[id] = workflow.hash
        reload()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled { settings.askDisabledWorkflows.remove(id) } else { settings.askDisabledWorkflows.insert(id) }
        reload()
    }

    func isEnabled(_ id: String) -> Bool { !settings.askDisabledWorkflows.contains(id) }

    /// Moves the workflow's folder to the Trash and forgets it, with its data and cache.
    func delete(_ id: String) throws {
        guard let workflow = workflow(id) else { return }
        try trash(workflow.folder)
        for directory in [AskWorkflow.dataDirectory(for: id, home: home), AskWorkflow.cacheDirectory(for: id, home: home)] {
            try? fileManager.removeItem(at: directory)
        }
        settings.askWorkflowTrust[id] = nil
        settings.askDisabledWorkflows.remove(id)
        reload()
    }

    // MARK: - Launcher

    /// The workflows that can be reached from the launcher (switched-off ones cannot),
    /// as plugins, with the run log and source app wired in.
    func plugins(source: @escaping @MainActor @Sendable () -> (app: String?, bundleID: String?)) -> [AskWorkflowPlugin] {
        let log = AskWorkflowLog.shared
        let home = home
        return workflows.filter { $0.manifest != nil && $0.status != .disabled }.map { workflow in
            AskWorkflowPlugin(workflow: workflow, source: source,
                              record: { entry in Task { @MainActor in log.add(entry) } }, home: home)
        }
    }

    /// The workflows' keywords that do not clash with `taken`, and the ones that do.
    static func keywords(of plugins: [AskWorkflowPlugin], excluding taken: [AskKeyword])
        -> (keywords: [AskKeyword], conflicts: [AskKeyword]) {
        var used = Set(taken.map(\.id))
        var keywords: [AskKeyword] = [], conflicts: [AskKeyword] = []
        for keyword in plugins.flatMap(\.defaultKeywords) {
            if used.contains(keyword.id) { conflicts.append(keyword) } else { keywords.append(keyword); used.insert(keyword.id) }
        }
        return (keywords, conflicts)
    }

    // MARK: - Templates

    /// Creates a workflow from a template, trusted since the user made it here.
    @discardableResult
    func create(_ template: AskWorkflowTemplate, takenKeywords: [AskKeyword]) throws -> AskWorkflow {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var number = 1
        var id = "local." + template.slug
        while fileManager.fileExists(atPath: root.appendingPathComponent(id).path) || workflow(id) != nil {
            number += 1
            id = "local.\(template.slug)-\(number)"
        }
        let taken = Set(takenKeywords.map(\.id) + workflows.flatMap { $0.manifest?.keywords.map { $0.keyword.lowercased() } ?? [] })
        var keyword = template.keyword
        var suffix = 2
        while taken.contains(keyword) { keyword = template.keyword + String(suffix); suffix += 1 }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = template.manifest(id: id, keyword: keyword)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent(AskWorkflowManifest.fileName))
        if let script = manifest.command.script {
            let url = folder.appendingPathComponent(script)
            try Data(template.script.utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        settings.askWorkflowTrust[id] = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        reload()
        return workflow(id) ?? AskWorkflow.load(folder: folder, trusted: nil, disabled: false, fileManager: fileManager)
    }

    /// Opens the workflows folder in Finder, creating it first.
    func revealRoot() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}

extension SettingsStore {
    /// The content hash each workflow had when the user trusted it, by workflow id.
    var askWorkflowTrust: [String: String] {
        get { (defaults.dictionary(forKey: "ask.workflows.trust") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "ask.workflows.trust") }
    }

    /// Workflows the user switched off.
    var askDisabledWorkflows: Set<String> {
        get { Set(defaults.stringArray(forKey: "ask.workflows.disabled") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "ask.workflows.disabled") }
    }
}
