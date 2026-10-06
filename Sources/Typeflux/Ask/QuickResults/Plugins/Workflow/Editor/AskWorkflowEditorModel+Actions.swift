import Foundation

/// New workflows, test runs and the assistant's proposals for the workflow editor.
extension AskWorkflowEditorModel {
    // MARK: - New workflows

    /// Opening something else needs the current edits saved or discarded first.
    private func settledForSwitch() -> Bool {
        guard isDirty || generation != nil else { return true }
        message = L("ask.workflow.editor.saveBeforeSwitch")
        return false
    }

    func create(_ template: AskWorkflowTemplate, name: String, keyword: String, id: String) -> Bool {
        guard settledForSwitch() else { return false }
        do {
            let created = try store.create(template, name: name, keyword: keyword, id: id, builtIn: builtInKeywords)
            open(created.id)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func duplicate(_ sourceID: String, name: String, keyword: String, id: String) -> Bool {
        guard settledForSwitch() else { return false }
        do {
            let copy = try store.duplicate(sourceID, name: name, keyword: keyword, id: id, builtIn: builtInKeywords)
            open(copy.id)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    /// Starts a generated workflow: a staging folder with a skeleton manifest, and the
    /// assistant asked to write it. Nothing reaches the workflows folder until saved.
    func generate(description: String, name: String, keyword: String, id: String,
                  runtime: AskWorkflowRuntime?) -> Bool {
        guard settledForSwitch() else { return false }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return false }
        if let problem = store.keywordProblem(keyword, builtIn: builtInKeywords) {
            message = problem; return false
        }
        guard AskWorkflowManifest.isValidID(id), store.workflow(id) == nil else {
            message = L("ask.workflow.editor.error.duplicateID", id)
            return false
        }
        let template: AskWorkflowTemplate = switch runtime {
        case .node: .nodeText
        case .zsh, .bash: .shellText
        default: .pythonText
        }
        var manifest = template.manifest(id: id, keyword: keyword)
        manifest.name = name.isEmpty ? keyword : name
        manifest.description = nil
        guard let data = try? AskWorkflowStore.encode(manifest) else { return false }
        var skeleton = AskWorkflowDraft(
            folder: staging.root,
            manifestText: String(bytes: data, encoding: .utf8) ?? "",
            files: [:]
        )
        if let script = manifest.command.script {
            skeleton.files[script] = template.script
        }
        do {
            stopWatching()
            endSession()
            let folder = try staging.make(skeleton, fileManager: store.fileManager)
            workflowID = nil
            generation = Generation(folder: folder)
            load(folder)
            draft?.markSaved()
            approvedRisks = nil
            proposals = []
            results = []
            assistant.bind(workflowID: nil)
            step = .script
            let language = runtime.map { L("ask.workflow.assistant.generate.runtime", $0.title) } ?? ""
            assistant.send(L("ask.workflow.assistant.generate.prompt", description, keyword, id) + language)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func saveGeneration(_ draft: AskWorkflowDraft, folder: URL) -> Bool {
        do {
            try AskWorkflowStore.write(
                draft.pendingWrites,
                deletes: draft.deletedPaths,
                in: folder,
                fileManager: store.fileManager
            )
            let installed = try store.install(from: folder)
            generation = nil
            assistant.rebind(to: installed.id)
            workflowID = installed.id
            load(installed.folder)
            approvedRisks = AskWorkflowRiskScanner.scan(self.draft?.files ?? [:])
            startWatching()
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func discardGeneration() {
        if let generation {
            staging.remove(generation.folder, fileManager: store.fileManager)
        }
        generation = nil
    }

    func delete() {
        guard let id = workflowID else { return }
        do {
            try store.delete(id)
            AskWorkflowAssistant.forget(workflowID: id)
            close()
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Test runs

    /// Saves, then runs the workflow as the launcher would (§7).
    func runTest() {
        guard !isTesting else { return }
        if generation != nil {
            message = L("ask.workflow.editor.test.saveFirst")
            return
        }
        guard save(), let workflow else { return }
        let trusted = workflow.status == .ready
            || (workflow.status == .disabled && store.settings.askWorkflowTrust[workflow.id] == workflow.hash)
        guard trusted else {
            message = workflow.blockedReason ?? L("ask.workflow.blocked.untrusted")
            return
        }
        let input = AskWorkflowTestInput(
            query: testQuery,
            selection: testUsesSelection ? testSelection : nil,
            keyword: testKeyword
        )
        isTesting = true
        testStartedAt = Date()
        let tester = tester
        testTask = Task { [weak self] in
            let result = await tester.run(workflow, input: input)
            guard let self, !Task.isCancelled else { return }
            results.append(result)
            if results.count > 20 {
                results.removeFirst(results.count - 20)
            }
            isTesting = false
            testStartedAt = nil
            if let location = failureLocation {
                selectedFile = location.path
                step = .script
                reveal = (location.path, location.line)
            }
        }
    }

    func stopTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        testStartedAt = nil
    }

    /// Asks the assistant to fix the last failed run.
    func fixWithAssistant() {
        guard let last = results.last, !last.succeeded else { return }
        var text = L("ask.workflow.assistant.fix.prompt", last.input.query, Int(last.exitCode))
        if let location = failureLocation {
            text += "\n" + L(
                "ask.workflow.assistant.fix.location",
                location.path,
                location.line
            )
        }
        text += "\n\n" + AskWorkflowAuthorTools.tail(last.stderr, limit: 2000)
        assistant.send(text)
    }

    // MARK: - Proposals

    func proposal(_ id: UUID) -> AskWorkflowProposal? {
        proposals.first { $0.id == id }
    }

    var latestProposal: AskWorkflowProposal? {
        proposals.last { $0.state == .pending }
    }

    /// Applies a proposal to the draft. It is saved like any edit; until then it can be undone.
    func apply(_ id: UUID) {
        guard let index = proposals.firstIndex(where: { $0.id == id }), let current = draft else { return }
        undoDraft = current
        canUndoProposal = true
        draft = proposals[index].applied(to: current)
        proposals[index].state = .applied
        // Applying is approving what it does.
        approvedRisks = proposals[index].risks
        previewingProposal = nil
        if let script = draft?.manifest?.command.script, draft?.files[script] != nil {
            selectedFile = script
        }
    }

    func discard(_ id: UUID) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[index].state = .discarded
        if previewingProposal == id {
            previewingProposal = nil
        }
    }

    func undoProposal() {
        guard let undoDraft else { return }
        draft = undoDraft
        self.undoDraft = nil
        canUndoProposal = false
    }

    /// Lets the assistant's waiting test run go ahead, or not.
    func resolvePendingRun(_ allowed: Bool) {
        if allowed, let pendingRun, let proposal = proposal(pendingRun.proposalID) {
            approvedRisks = proposal.risks
        }
        pendingRun = nil
        pendingRunContinuation?.resume(returning: allowed)
        pendingRunContinuation = nil
    }
}

extension AskWorkflowEditorModel {
    /// A generated workflow can be saved once the assistant proposed something that
    /// has no problems (applied already, or about to be).
    var canSaveGenerated: Bool {
        guard generation != nil, let draft else { return false }
        guard latestProposal != nil || proposals.contains(where: { $0.state == .applied }) else { return false }
        let candidate = latestProposal?.applied(to: draft) ?? draft
        return candidate.problems(fileManager: store.fileManager).isEmpty
    }

    /// "Review and save" for a generated workflow: the latest proposal goes into the
    /// draft, then the workflow is installed and trusted.
    @discardableResult
    func saveGenerated() -> Bool {
        guard generation != nil else { return false }
        if let latest = latestProposal {
            apply(latest.id)
        }
        return save()
    }
}
