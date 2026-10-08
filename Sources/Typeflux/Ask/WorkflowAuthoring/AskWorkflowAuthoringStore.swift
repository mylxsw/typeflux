import Foundation

/// Local drafts are partitioned by account and conversation, outside installed packages.
@MainActor
final class AskWorkflowAuthoringStore {
    let workflows: AskWorkflowStore
    let root: URL
    let staging: AskWorkflowStaging
    let owner: () -> String
    var onChange: (() -> Void)?
    private var sessions: [String: AskWorkflowAuthoringSession] = [:]
    private var loaded: Set<String> = []

    init(workflows: AskWorkflowStore, root: URL? = nil,
         staging: AskWorkflowStaging = .init(root: AskWorkflowStaging.defaultRoot().deletingLastPathComponent()
            .appendingPathComponent("ChatWorkflowPreviews")), owner: @escaping () -> String) {
        self.workflows = workflows; self.owner = owner
        self.staging = staging
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Typeflux/WorkflowAuthoring")
        // Previous-process leftovers only; live previews are owned by sessions.
        staging.prune()
    }

    private func key(_ conversation: String) -> String {
        AskToolPolicy.digest(owner()) + "/" + AskToolPolicy.digest(conversation)
    }

    func session(_ conversation: String) -> AskWorkflowAuthoringSession? {
        let key = key(conversation)
        if let session = sessions[key] { return session }
        guard loaded.insert(key).inserted else { return nil }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(key + ".json")),
              let record = try? JSONDecoder().decode(AskWorkflowAuthoringSession.Record.self, from: data) else { return nil }
        workflows.reload()
        return bind(record, key: key)
    }

    func start(_ conversation: String, name: String, workflowID: String?) throws -> AskWorkflowAuthoringSession {
        if let current = session(conversation), current.isDirty {
            throw AskLocalError.message(L("ask.workflow.chat.existingDraft"))
        }
        workflows.reload()
        let record: AskWorkflowAuthoringSession.Record
        if let workflowID {
            guard let workflow = workflows.workflow(workflowID) else {
                throw AskLocalError.message(L("ask.workflow.editor.missing"))
            }
            record = .init(draft: .load(folder: workflow.folder), workflowID: workflowID, expectedHash: workflow.hash)
        } else {
            let id = workflows.suggestedID(for: name)
            var manifest = AskWorkflowTemplate.pythonText.manifest(id: id, keyword: "")
            manifest.name = name; manifest.keywords = []
            let draft = AskWorkflowDraft(folder: staging.root.appendingPathComponent(UUID().uuidString),
                                         manifestText: String(decoding: try AskWorkflowStore.encode(manifest), as: UTF8.self),
                                         files: [:])
            record = .init(draft: draft)
        }
        let key = key(conversation)
        sessions[key]?.close()
        let result = bind(record, key: key)
        try persist(result, key: key)
        onChange?()
        return result
    }

    private func bind(_ record: AskWorkflowAuthoringSession.Record, key: String) -> AskWorkflowAuthoringSession {
        var tester = AskWorkflowTester()
        tester.language = workflows.settings.appLanguage
        let session = AskWorkflowAuthoringSession(store: workflows, record: record, staging: staging, tester: tester)
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            do { try self.persist(session, key: key) }
            catch { session.message = error.localizedDescription }
            self.onChange?()
        }
        sessions[key] = session
        return session
    }

    private func persist(_ session: AskWorkflowAuthoringSession, key: String) throws {
        let url = root.appendingPathComponent(key + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session.record).write(to: url, options: .atomic)
    }

    func remove(_ conversation: String) throws {
        let key = key(conversation)
        sessions.removeValue(forKey: key)?.close()
        let url = root.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        onChange?()
    }

    func reset() {
        sessions.values.forEach { $0.close() }
        sessions = [:]
        loaded = []
        onChange?()
    }
}
