import Foundation

/// One conversation's working copy. Only explicit save publishes to the launcher.
@MainActor
final class AskWorkflowAuthoringSession: ObservableObject, AskWorkflowAuthoringHost {
    struct Record: Codable {
        var draft: AskWorkflowDraft
        var workflowID: String?
        var expectedHash: String?
    }

    struct Preview {
        let revision: UUID
        let manifest: AskWorkflowManifest
        let folder: URL
        let result: AskWorkflowTestResult
    }

    let store: AskWorkflowStore
    let staging: AskWorkflowStaging
    var tester: AskWorkflowTester
    var onChange: (() -> Void)?
    @Published private(set) var draft: AskWorkflowDraft
    @Published private(set) var workflowID: String?
    @Published private(set) var revision = UUID()
    @Published private(set) var preview: Preview?
    @Published private(set) var isRunning = false
    @Published var isPresented = true
    @Published var query = ""
    @Published var selection = ""
    @Published var keyword = ""
    @Published var message: String?
    @Published private(set) var proposals: [AskWorkflowProposal] = []
    private(set) var expectedHash: String?
    private var runID: UUID?
    private var runTask: Task<[AskWorkflowTestResult]?, Never>?
    private var undoDraft: AskWorkflowDraft?

    init(store: AskWorkflowStore, record: Record, staging: AskWorkflowStaging = .init(),
         tester: AskWorkflowTester = .init()) {
        self.store = store; self.staging = staging; self.tester = tester
        draft = record.draft; workflowID = record.workflowID; expectedHash = record.expectedHash
        keyword = draft.manifest?.keywords.first?.keyword ?? ""
    }

    var record: Record { .init(draft: draft, workflowID: workflowID, expectedHash: expectedHash) }
    var authoringDraft: AskWorkflowDraft { draft }
    var authoringWorkflowID: String? { workflowID }
    var lastTestResult: AskWorkflowTestResult? { preview?.result }
    var canUndo: Bool { undoDraft != nil }
    var risks: Set<AskWorkflowRisk> { AskWorkflowRiskScanner.scan(draft.scannedFiles) }
    var isDirty: Bool { workflowID == nil || draft.isDirty }
    var problems: [String] { fieldProblems.map(\.message) }

    /// Every problem with the manifest field it belongs to, so the panel's
    /// checklist can mark the item it concerns.
    var fieldProblems: [AskWorkflowManifest.Problem] {
        var values = draft.problems()
        for (index, keyword) in (draft.manifest?.keywords ?? []).enumerated() {
            if let problem = keywordProblem(keyword.keyword) {
                values.append(.init(field: "keywords[\(index)]", message: problem))
            }
        }
        if let workflowID, draft.manifest?.id != workflowID {
            values.append(.init(field: "id", message: L("ask.workflow.chat.idChanged")))
        }
        return values
    }

    var checklist: AskWorkflowChecklist { .init(manifest: draft.manifest, problems: fieldProblems) }

    /// The latest test run, only while it still describes the current draft.
    var currentPreview: Preview? { preview?.revision == revision ? preview : nil }

    func keywordProblem(_ keyword: String) -> String? {
        store.keywordProblem(keyword, builtIn: store.settings.effectiveAskLauncherKeywords, excluding: workflowID)
    }

    func submit(_ proposal: AskWorkflowProposal) -> AskWorkflowProposal {
        var proposal = proposal
        let candidate = proposal.applied(to: draft)
        proposal.risks = AskWorkflowRiskScanner.scan(candidate.scannedFiles)
        proposal.newRisks = proposal.risks.subtracting(risks)
        for index in proposals.indices { proposals[index].state = .superseded }
        proposals.append(proposal)
        // Bound in-memory history; the complete current draft is persisted separately.
        proposals = Array(proposals.suffix(20))
        replaceDraft(candidate)
        isPresented = true
        return proposal
    }

    func edit(text: String, path: String) {
        guard draft.paths.contains(path) else { return }
        var candidate = draft
        candidate.setText(text, of: path)
        replaceDraft(candidate)
    }

    func undo() {
        guard let previous = undoDraft else { return }
        replaceDraft(previous)
        undoDraft = nil
    }

    private func replaceDraft(_ candidate: AskWorkflowDraft) {
        cancel()
        clearPreview()
        undoDraft = draft; draft = candidate; revision = UUID(); message = nil
        if !(draft.manifest?.keywords.contains { $0.keyword == keyword } ?? false) {
            keyword = draft.manifest?.keywords.first?.keyword ?? ""
        }
        onChange?()
    }

    func cancel() {
        runID = nil; runTask?.cancel(); runTask = nil; isRunning = false
    }

    func close() {
        cancel(); clearPreview(); isPresented = false
    }

    private func clearPreview() {
        if let preview { staging.remove(preview.folder) }
        preview = nil
    }

    /// The caller has obtained approval for this exact revision. Actions are described,
    /// never performed here; executing the script itself still has real local effects.
    func testLatestProposal(_ inputs: [AskWorkflowTestInput]) async -> [AskWorkflowTestResult]? {
        guard !Task.isCancelled, !inputs.isEmpty, inputs.count <= AskWorkflowAuthorTools.maximumInputs else { return nil }
        cancel(); clearPreview(); message = nil
        guard problems.isEmpty, let manifest = draft.manifest else {
            message = problems.first; return nil
        }
        let snapshot = draft, revision = revision, id = UUID(), tester = tester, staging = staging
        let folder: URL
        do { folder = try staging.make(snapshot, copying: try sourceFolder()) }
        catch { message = error.localizedDescription; return nil }
        let hash = AskWorkflow.contentHash(of: folder)
        let workflow = AskWorkflow.load(folder: folder, trusted: hash, disabled: false)
        runID = id; isRunning = true
        let task = Task { @MainActor [weak self] () -> [AskWorkflowTestResult]? in
            var retained = false
            defer {
                if !retained { staging.remove(folder) }
                if self?.runID == id { self?.isRunning = false; self?.runTask = nil; self?.runID = nil }
            }
            var results: [AskWorkflowTestResult] = []
            for input in inputs {
                guard !Task.isCancelled, self?.runID == id else { return nil }
                let result = await tester.run(workflow, input: input)
                guard !Task.isCancelled, let self, self.runID == id, self.revision == revision else { return nil }
                results.append(result)
            }
            guard let self, self.runID == id, !Task.isCancelled, let result = results.last else { return nil }
            self.preview = Preview(revision: revision, manifest: manifest, folder: folder, result: result)
            retained = true
            return results
        }
        runTask = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Do not silently copy changed binaries or resources into an approved snapshot.
    private func sourceFolder() throws -> URL? {
        guard let workflowID else { return nil }
        guard let source = store.workflow(workflowID),
              AskWorkflow.contentHash(of: source.folder) == expectedHash else {
            throw AskLocalError.message(L("ask.workflow.chat.conflict"))
        }
        return source.folder
    }

    @discardableResult
    func save() throws -> AskWorkflow {
        store.reload()
        guard problems.isEmpty, let manifest = draft.manifest else {
            throw AskLocalError.message(problems.first ?? L("ask.workflow.invalid"))
        }
        let workflow: AskWorkflow
        if let workflowID, let folder = try sourceFolder() {
            let result = try store.save(workflowID, folder: folder, writes: draft.pendingWrites,
                                        deletes: draft.deletedPaths, expectedHash: expectedHash)
            guard case .saved = result, let saved = store.workflow(workflowID) else {
                throw AskLocalError.message(L("ask.workflow.chat.conflict"))
            }
            workflow = saved
        } else {
            let folder = try staging.make(draft)
            defer { staging.remove(folder) }
            workflow = try store.install(from: folder)
        }
        workflowID = manifest.id; expectedHash = workflow.hash
        draft = AskWorkflowDraft.load(folder: workflow.folder)
        undoDraft = nil; message = L("ask.workflow.chat.saved"); onChange?()
        return workflow
    }
}
