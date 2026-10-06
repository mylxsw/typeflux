import AppKit
import Foundation

/// The workflow editor's state: which workflow is open, its draft, saving under
/// the trust rules, outside changes, test runs, and the assistant's proposals.
/// See `docs/design/ask-workflow-editor.md`.
@MainActor
final class AskWorkflowEditorModel: ObservableObject {
    enum ConfigMode: String { case form, json }

    /// A file changed outside the editor while the draft had unsaved edits.
    struct OutsideChange: Equatable {
        var hash: String
        var disk: AskWorkflowDraft
        var detectedAt = Date()
    }

    /// Where the caret is in the code view, for the status bar.
    struct Cursor: Equatable {
        var line: Int
        var column: Int
    }

    /// A generated workflow waiting in its staging folder until the user saves it.
    struct Generation: Equatable {
        var folder: URL
    }

    /// The assistant wants to run code with risks the user has not approved.
    struct PendingRun: Equatable {
        var proposalID: UUID
        var risks: [AskWorkflowRisk]
    }

    let store: AskWorkflowStore
    let settings: SettingsStore
    let assistant: AskWorkflowAssistant
    var tester: AskWorkflowTester
    var staging = AskWorkflowStaging()
    /// How often the open folder is checked for outside changes.
    var watchInterval: TimeInterval = 2

    @Published var workflowID: String?
    @Published var generation: Generation?
    @Published var draft: AskWorkflowDraft?
    @Published var step: AskWorkflowDraft.Step = .script
    @Published var configMode: ConfigMode = .form
    @Published var selectedFile: String?
    /// The line the code view scrolls to and marks, once.
    @Published var reveal: (path: String, line: Int)?
    @Published var search = ""
    @Published var message: String?
    @Published private(set) var outsideChange: OutsideChange?
    @Published var showingDiff = false
    @Published var cursor: Cursor?
    /// "Python 3.12.1 · /opt/homebrew/bin/python3" for the status bar, once looked up.
    @Published var runtimeInfo: String?
    /// The run the user asked to find something in; the code view shows its find bar.
    @Published var findRequest = 0
    var runtimeProbe = AskWorkflowEnvironmentProbe()

    // Test runs.
    @Published var testQuery = ""
    @Published var testSelection = ""
    @Published var testUsesSelection = false
    @Published var testKeyword: String?
    @Published var isTesting = false
    /// When the running test started, for "Running · 1.2 s".
    @Published var testStartedAt: Date?
    @Published var results: [AskWorkflowTestResult] = []

    // Assistant.
    @Published var proposals: [AskWorkflowProposal] = []
    @Published var previewingProposal: UUID?
    @Published var pendingRun: PendingRun?
    /// Run the assistant's code without asking unless a new risk appears.
    @Published var autoTest = true
    var undoDraft: AskWorkflowDraft?
    @Published var canUndoProposal = false
    /// Risks of the version the user last approved; nil for a generated workflow before its first approval.
    var approvedRisks: Set<AskWorkflowRisk>?
    var pendingRunContinuation: CheckedContinuation<Bool, Never>?

    /// The folder's hash when the draft was loaded or last saved (§6.2's H0).
    var loadedHash = ""
    var testTask: Task<Void, Never>?
    private var watchTimer: Timer?

    init(store: AskWorkflowStore, settings: SettingsStore, assistant: AskWorkflowAssistant,
         tester: AskWorkflowTester = AskWorkflowTester(record: { entry in Task { @MainActor in
             AskWorkflowLog.shared.add(entry)
         } })) {
        self.store = store
        self.settings = settings
        self.assistant = assistant
        self.tester = tester
        assistant.host = self
    }

    // MARK: - Opening

    var builtInKeywords: [AskKeyword] {
        settings.effectiveAskLauncherKeywords
    }

    var workflow: AskWorkflow? {
        workflowID.flatMap { store.workflow($0) }
    }

    var folder: URL? {
        generation?.folder ?? workflow?.folder
    }

    var filteredWorkflows: [AskWorkflow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.workflows }
        return store.workflows.filter { workflow in
            (workflow.manifest?.name ?? workflow.id).lowercased().contains(query) || workflow.id.lowercased()
                .contains(query)
                || (workflow.manifest?.keywords ?? []).contains { $0.keyword.lowercased().contains(query) }
        }
    }

    /// Opens a workflow, optionally at a line of a file. Unsaved edits are the caller's to settle first.
    func open(_ id: String, path: String? = nil, line: Int? = nil) {
        store.reload()
        guard let workflow = store.workflow(id) else { message = L("ask.workflow.editor.missing"); return }
        endSession()
        workflowID = id
        load(workflow.folder)
        approvedRisks = AskWorkflowRiskScanner.scan(draft?.files ?? [:])
        proposals = []
        previewingProposal = nil
        results = []
        assistant.bind(workflowID: id)
        if let path, draft?.text(of: path) != nil {
            selectedFile = path
            step = path == AskWorkflowManifest.fileName ? .keywords : .script
            if path == AskWorkflowManifest.fileName {
                configMode = .json
            }
            if let line {
                reveal = (path, line)
            }
        } else {
            step = .script
        }
        startWatching()
    }

    /// Where an outside request (settings, the launcher) wants the editor. Unsaved
    /// edits are never saved or dropped behind the user's back: the same workflow
    /// only scrolls to the line, another one waits until the user saves or discards.
    func navigate(to id: String?, path: String? = nil, line: Int? = nil) {
        guard let id else {
            if draft == nil {
                store.reload()
                if let first = store.workflows.first {
                    open(first.id)
                }
            }
            return
        }
        if id == workflowID, generation == nil {
            guard let path, draft?.text(of: path) != nil else { return }
            selectedFile = path
            step = path == AskWorkflowManifest.fileName ? .keywords : .script
            if path == AskWorkflowManifest.fileName {
                configMode = .json
            }
            if let line {
                reveal = (path, line)
            }
        } else if isDirty || generation != nil {
            message = L("ask.workflow.editor.saveBeforeSwitch")
        } else {
            open(id, path: path, line: line)
        }
    }

    func load(_ folder: URL) {
        let loaded = AskWorkflowDraft.load(folder: folder, fileManager: store.fileManager)
        draft = loaded
        loadedHash = AskWorkflow.contentHash(of: folder, fileManager: store.fileManager)
        outsideChange = nil
        showingDiff = false
        undoDraft = nil
        canUndoProposal = false
        let script = loaded.manifest?.command.script
        selectedFile = script.flatMap { loaded.files[$0] != nil ? $0 : nil } ?? loaded.files.keys.sorted().first
            ?? AskWorkflowManifest.fileName
        testKeyword = loaded.manifest?.keywords.first?.keyword
        cursor = nil
        refreshRuntimeInfo()
    }

    /// Closes the editor's workflow (the window closed).
    func close() {
        stopWatching()
        endSession()
        workflowID = nil
        draft = nil
    }

    /// Ends what belongs to the open workflow: a test run, the assistant's turn and
    /// a run waiting for approval (its tool call gets a refusal), a staged generation.
    func endSession() {
        stopTest()
        resolvePendingRun(false)
        assistant.stop()
        discardGeneration()
    }

    var isDirty: Bool {
        draft?.isDirty == true
    }

    // MARK: - Editing

    func setText(_ text: String, of path: String) {
        guard draft?.text(of: path) != text else { return }
        draft?.setText(text, of: path)
    }

    /// Sets a manifest field from the form; no-op while the JSON does not parse.
    func set(_ value: Any?, at path: [String]) {
        guard var current = draft else { return }
        if current.set(value, at: path) {
            draft = current
        }
    }

    func formatManifest() {
        guard let text = draft?.formattedManifest() else { return }
        draft?.manifestText = text
    }

    /// Adds an empty text file next to the script.
    func addFile(_ path: String) {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard draft != nil, AskWorkflowProposal.problem(files: [path: ""], deletes: []) == nil,
              draft?.text(of: path) == nil else { message = L("ask.workflow.editor.error.pathOutside", path); return }
        draft?.files[path] = ""
        selectedFile = path
        step = .script
    }

    func removeFile(_ path: String) {
        guard path != AskWorkflowManifest.fileName else { return }
        draft?.files[path] = nil
        if selectedFile == path {
            selectedFile = draft?.files.keys.sorted().first ?? AskWorkflowManifest.fileName
        }
    }

    // MARK: - Saving

    /// Saves under §6.2. Returns false when nothing could be written (a conflict or an error).
    @discardableResult
    func save() -> Bool {
        guard let draft else { return false }
        if let generation {
            return saveGeneration(draft, folder: generation.folder)
        }
        guard let id = workflowID else { return false }
        let folder = workflow?.folder ?? draft.folder
        guard draft.isDirty else { return true }
        do {
            switch try store.save(id, folder: folder, writes: draft.pendingWrites, deletes: draft.deletedPaths,
                                  expectedHash: loadedHash) {
            case let .saved(hash, _):
                finishSave(hash: hash)
                return true
            case let .conflict(currentHash):
                outsideChange = OutsideChange(
                    hash: currentHash,
                    disk: AskWorkflowDraft.load(folder: folder, fileManager: store.fileManager)
                )
                message = L("ask.workflow.editor.conflict")
                return false
            }
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func finishSave(hash: String) {
        loadedHash = hash
        draft?.markSaved()
        // The saved version is what the user approved.
        approvedRisks = AskWorkflowRiskScanner.scan(draft?.files ?? [:])
        let newID = draft?.manifest?.id
        if let newID, newID != workflowID, store.workflow(newID) != nil {
            AskWorkflowAssistant.forget(workflowID: workflowID ?? "")
            workflowID = newID
            assistant.rebind(to: newID)
        }
        message = nil
    }

    /// Writes over an outside change. Trust is never granted this way.
    func keepMine() {
        guard let draft, let id = workflowID, let folder = workflow?.folder else { return }
        do {
            if case let .saved(hash, _) = try store.save(id, folder: folder, writes: draft.pendingWrites,
                                                         deletes: draft.deletedPaths, expectedHash: nil) {
                finishSave(hash: hash)
                outsideChange = nil
            }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Drops unsaved edits for what is on disk now.
    func loadTheirs() {
        guard let folder = workflow?.folder else { return }
        store.reload()
        load(folder)
    }

    /// Confirms the workflow as its files are now (the trust sheet's button).
    func trust() {
        guard let id = workflowID else { return }
        store.reload()
        store.trust(id)
        if let folder = workflow?.folder, draft?.isDirty != true {
            load(folder)
        }
        outsideChange = nil
    }
}

extension AskWorkflowEditorModel {
    // MARK: - Problems

    /// The draft's own problems, and keywords another workflow or a built-in plugin already uses.
    var problems: [AskWorkflowManifest.Problem] {
        guard let draft else { return [] }
        var problems = draft.problems(fileManager: store.fileManager)
        for (index, keyword) in (draft.manifest?.keywords ?? []).enumerated() {
            let field = "keywords[\(index)]"
            guard !problems.contains(where: { $0.field == field }),
                  let problem = keywordProblem(keyword.keyword) else { continue }
            problems.append(.init(field: field, message: keyword.keyword + ": " + problem))
        }
        return problems
    }

    func problems(for step: AskWorkflowDraft.Step) -> [AskWorkflowManifest.Problem] {
        problems.filter { AskWorkflowDraft.step(for: $0.field) == step }
    }

    /// Marks for the code view: manifest problems in `workflow.json`, the last failed
    /// test run's line in the script.
    func markers(for path: String) -> [Int: String] {
        guard let draft else { return [:] }
        var markers: [Int: String] = [:]
        if path == AskWorkflowManifest.fileName {
            for problem in problems {
                if let line = draft.line(for: problem.field) {
                    markers[line] = problem.message
                }
            }
        } else if let location = failureLocation, location.path == path {
            markers[location.line] = location.message
        }
        return markers
    }

    var failureLocation: AskWorkflowStderrLocator.Location? {
        guard let last = results.last, !last.succeeded, let draft else { return nil }
        return AskWorkflowStderrLocator.locate(
            last.stderr,
            folder: folder ?? draft.folder,
            files: Set(draft.files.keys)
        )
    }

    /// The trust the open workflow needs before it may run.
    var needsTrust: Bool {
        guard generation == nil, let workflow else { return false }
        return workflow.status == .untrusted || workflow.status == .modified
    }

    // MARK: - Watching

    func startWatching() {
        stopWatching()
        guard watchInterval > 0 else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkOutside() }
        }
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// Looks for outside changes: reloads a clean draft, flags a dirty one.
    func checkOutside() async {
        guard generation == nil, let folder = workflow?.folder, outsideChange == nil else { return }
        let fileManager = FileManager.default
        let hash = await Task.detached(priority: .utility) { AskWorkflow.contentHash(
            of: folder,
            fileManager: fileManager
        ) }.value
        guard hash != loadedHash, workflow?.folder == folder else { return }
        store.reload()
        if draft?.isDirty == true {
            outsideChange = OutsideChange(
                hash: hash,
                disk: AskWorkflowDraft.load(folder: folder, fileManager: store.fileManager)
            )
        } else {
            let selected = selectedFile
            load(folder)
            if let selected, draft?.text(of: selected) != nil {
                selectedFile = selected
            }
        }
    }
}

// MARK: - Assistant host

extension AskWorkflowEditorModel: AskWorkflowAuthoringHost {
    var authoringDraft: AskWorkflowDraft {
        let base = draft ?? AskWorkflowDraft(folder: staging.root, manifestText: "", files: [:])
        return latestProposal?.applied(to: base) ?? base
    }

    var authoringWorkflowID: String? {
        generation == nil ? workflowID : nil
    }

    var lastTestResult: AskWorkflowTestResult? {
        latestProposal?.tests.last ?? results.last
    }

    func keywordProblem(_ keyword: String) -> String? {
        store.keywordProblem(keyword, builtIn: builtInKeywords, excluding: generation == nil ? workflowID : nil)
    }

    func submit(_ proposal: AskWorkflowProposal) -> AskWorkflowProposal {
        var proposal = proposal
        let result = proposal.applied(to: draft ?? authoringDraft)
        proposal.risks = AskWorkflowRiskScanner.scan(result.files)
        proposal.newRisks = AskWorkflowRiskScanner.newRisks(proposal.risks,
                                                            since: approvedRisks ?? AskWorkflowRiskScanner
                                                                .scan(draft?.files ?? [:]))
        for index in proposals.indices where proposals[index].state == .pending {
            proposals[index].state = .discarded
        }
        proposals.append(proposal)
        return proposal
    }

    func testLatestProposal(_ inputs: [AskWorkflowTestInput]) async -> [AskWorkflowTestResult]? {
        guard let proposal = latestProposal, let base = draft else { return nil }
        if !autoTest || AskWorkflowRiskScanner.needsApproval(proposal.risks, baseline: approvedRisks) {
            let risks = autoTest ?
                (approvedRisks.map { proposal.risks.subtracting($0) } ?? proposal.risks.filter(\.isHigh))
                : proposal.risks
            pendingRun = PendingRun(proposalID: proposal.id, risks: risks.sorted())
            let allowed = await withCheckedContinuation { pendingRunContinuation = $0 }
            guard allowed else { return nil }
        }
        let candidate = proposal.applied(to: base)
        let fileManager = store.fileManager
        guard let folder = try? staging.make(candidate, copying: folder, fileManager: fileManager) else { return nil }
        defer { staging.remove(folder, fileManager: fileManager) }
        let hash = AskWorkflow.contentHash(of: folder, fileManager: fileManager)
        let workflow = AskWorkflow.load(folder: folder, trusted: hash, disabled: false, fileManager: fileManager)
        var runs: [AskWorkflowTestResult] = []
        for input in inputs {
            if Task.isCancelled {
                break
            }
            await runs.append(tester.run(workflow, input: input))
        }
        if let index = proposals.firstIndex(where: { $0.id == proposal.id }) {
            proposals[index].tests += runs
        }
        return runs
    }
}
