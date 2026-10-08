import Foundation
import Testing
@testable import Typeflux

@Suite("Workflow authoring in Chat")
@MainActor
struct AskWorkflowAuthoringTests {
    private func authoring(_ fixture: AskWorkflowFixture, owner: @escaping () -> String = { "alice" }) -> AskWorkflowAuthoringStore {
        .init(workflows: fixture.store, root: fixture.home.appendingPathComponent("Authoring"),
              staging: .init(root: fixture.home.appendingPathComponent("previews")), owner: owner)
    }

    private func proposal(_ session: AskWorkflowAuthoringSession, script: String = "print hello",
                          output: String = "text") -> AskWorkflowProposal {
        let object = AskWorkflowFixture.inline(session.draft.manifest!.id, keyword: "wfchat", script: script, output: output)
        return .init(summary: "Updated", manifestText: AskWorkflowDraft.format(object), files: [:], deletes: [])
    }

    private func call(_ name: String, _ args: [String: Any] = [:]) throws -> AskToolCall {
        .init(id: UUID().uuidString, function: .init(name: name,
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)))
    }

    @Test func draftsPersistByOwnerAndConversationWithoutInstalling() throws {
        let fixture = try AskWorkflowFixture()
        var owner = "alice"
        let store = authoring(fixture, owner: { owner })
        let session = try store.start("one", name: "Unique lines", workflowID: nil)
        _ = session.submit(proposal(session))
        #expect(session.isDirty && session.canUndo)
        #expect(session.authoringWorkflowID == nil && session.problems.isEmpty)
        #expect(fixture.store.workflows.isEmpty)
        #expect(store.session("two") == nil)
        #expect(throws: (any Error).self) { try store.start("one", name: "Replacement", workflowID: nil) }
        let restored = try #require(authoring(fixture).session("one"))
        #expect(restored.draft == session.draft)
        owner = "bob"
        #expect(store.session("one") == nil)
        owner = "alice"
        store.reset()
        #expect(store.session("one")?.draft == session.draft)
        try store.remove("one")
        #expect(store.session("one") == nil)
        try store.remove("absent")
    }

    @Test func proposalUndoAndAdvancedEditingUseOneDraft() throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Tool", workflowID: nil)
        _ = session.submit(proposal(session))
        let baseline = session.draft, revision = session.revision
        session.edit(text: "invalid JSON", path: "workflow.json")
        #expect(session.revision != revision && !session.problems.isEmpty)
        session.undo()
        #expect(session.draft == baseline && !session.canUndo)
        session.undo()
        session.edit(text: "do not add arbitrary paths", path: "../bad")
        #expect(session.draft == baseline)
        for index in 0..<25 { _ = session.submit(proposal(session, script: "print \(index)")) }
        #expect(session.proposals.count == 20)
        #expect(session.proposals.dropLast().allSatisfy { $0.state == .superseded })
    }

    @Test func explicitSaveInstallsAndConflictNeverOverwrites() throws {
        let fixture = try AskWorkflowFixture()
        let registry = authoring(fixture)
        let session = try registry.start("c", name: "Tool", workflowID: nil)
        #expect(throws: (any Error).self) { try session.save() }
        _ = session.submit(proposal(session))
        let saved = try session.save()
        #expect(saved.status == .ready && !session.isDirty)
        #expect(session.authoringWorkflowID == saved.id)
        _ = session.submit(proposal(session, script: "print revised"))
        let updated = try session.save()
        #expect(updated.hash != saved.hash && updated.status == .ready)
        _ = session.submit(proposal(session, script: "print draft"))
        let file = saved.folder.appendingPathComponent("workflow.json")
        let external = Data("external edit".utf8)
        try external.write(to: file)
        #expect(throws: (any Error).self) { try session.save() }
        #expect(try Data(contentsOf: file) == external)
    }

    @Test func openingInstalledDraftValidatesIdentityAndKeyword() throws {
        let fixture = try AskWorkflowFixture()
        _ = try fixture.store.create(.shellText, name: "First", keyword: "first", id: "local.first", builtIn: [])
        _ = try fixture.store.create(.shellText, name: "Second", keyword: "second", id: "local.second", builtIn: [])
        let registry = authoring(fixture)
        #expect(throws: (any Error).self) { try registry.start("c", name: "", workflowID: "missing") }
        let session = try registry.start("c", name: "", workflowID: "local.first")
        #expect(session.keywordProblem("first") == nil)
        #expect(session.keywordProblem("second") != nil)
        var draft = session.draft
        draft.set("local.renamed", at: ["id"])
        session.edit(text: draft.manifestText, path: "workflow.json")
        #expect(!session.problems.isEmpty)
        #expect(throws: (any Error).self) { try session.save() }
    }

    @Test func realRunsKeepPreviewAssetsAndNeverPublishTestWrites() async throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Image", workflowID: nil)
        defer { session.close() }
        let png = AskAttachmentFixture.encode(AskAttachmentFixture.image(width: 16, height: 16), type: .png)
        _ = session.submit(proposal(session,
            script: "print -r -- '\(png.base64EncodedString())' | /usr/bin/base64 -D > result.png; print result.png", output: "image"))
        session.tester.searchPath = { "/bin:/usr/bin" }
        let results = try #require(await session.testLatestProposal([.init(query: "input")]))
        #expect(results.count == 1 && results[0].succeeded)
        let preview = try #require(session.preview)
        #expect(FileManager.default.fileExists(atPath: preview.folder.appendingPathComponent("result.png").path))
        #expect(fixture.store.workflows.isEmpty && !session.isRunning)
        #expect(preview.result.input.query == "input" && preview.manifest.output.display == .image)
        let image = AskWorkflowImage.resolve("result.png", folder: preview.folder,
            cache: fixture.home.appendingPathComponent("images"), home: fixture.home.path)
        guard case .success = image else { Issue.record("Preview image must remain readable"); return }
        let saved = try session.save()
        #expect(!FileManager.default.fileExists(atPath: saved.folder.appendingPathComponent("result.png").path))
        _ = session.submit(proposal(session))
        #expect(session.preview == nil)
        #expect(!FileManager.default.fileExists(atPath: preview.folder.path))
    }

    @Test func cancelledOrEditedRunsCannotPublishLateResults() async throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Tool", workflowID: nil)
        _ = session.submit(proposal(session, script: "sleep 10; print stale"))
        session.tester.searchPath = { "/bin:/usr/bin" }
        let task = Task { await session.testLatestProposal([.init(query: "old")]) }
        for _ in 0..<1000 where !session.isRunning { await Task.yield() }
        #expect(session.isRunning)
        _ = session.submit(proposal(session, script: "print fresh"))
        #expect(await task.value == nil)
        #expect(session.preview == nil && !session.isRunning)
        let next = Task { await session.testLatestProposal([.init(query: "new")]) }
        next.cancel()
        #expect(await next.value == nil)
        session.close()
    }

    @Test func failuresAndMultipleInputsUseSnapshotAndGuardBounds() async throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Tool", workflowID: nil)
        defer { session.close() }
        #expect(await session.testLatestProposal([.init(query: "")]) == nil)
        #expect(session.message != nil)
        _ = session.submit(proposal(session, script: "print err >&2; exit 2"))
        session.tester.searchPath = { "/bin:/usr/bin" }
        #expect(await session.testLatestProposal([]) == nil)
        #expect(await session.testLatestProposal(Array(repeating: .init(query: ""), count: 6)) == nil)
        let results = try #require(await session.testLatestProposal([.init(query: "a"), .init(query: "b")]))
        #expect(results.count == 2 && results.allSatisfy { !$0.succeeded && $0.exitCode == 2 })
        #expect(session.lastTestResult?.input.query == "b")
        let folder = try #require(session.preview?.folder)
        session.close()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func toolsAreDiscoverableScopedAndExecutionRequiresFreshApproval() async throws {
        let fixture = try AskWorkflowFixture()
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: fixture.settings.defaults)),
                                  settings: fixture.settings)
        let authoring = authoring(fixture)
        tools.workflowAuthoring = authoring
        #expect(tools.workflowAuthoringEnabled)
        #expect(await tools.definitions(conversationId: "c").contains { $0.name == "workflow_start" })
        #expect(AskBuiltinSkills.all.contains { $0.name == AskWorkflowAuthorSkill.name })
        #expect(AskWorkflowAuthorSkill.chatInstructions.contains("one-off"))
        let read = try call("workflow_read")
        #expect(try await tools.execute(read, conversationId: "c").isError)
        _ = try await tools.execute(call("workflow_start", ["name": "Unique lines"]), conversationId: "c")
        let session = try #require(authoring.session("c"))
        let object = AskWorkflowFixture.inline(session.draft.manifest!.id, keyword: "wfchat", script: "print hello")
        let output = try await tools.execute(call("workflow_propose", ["summary": "First", "manifest": object]), conversationId: "c")
        #expect(!output.isError && fixture.store.workflows.isEmpty)
        let test = try call("workflow_test", ["inputs": [["query": ""]]])
        #expect(tools.risk(of: test) == .destructive)
        #expect(tools.risk(of: read) == .read)
        for name in AskLocalTools.workflowChatNames {
            #expect(AskTheme.toolTitle(try call(name)) != name)
            #expect(!AskTheme.toolTitle(try call(name)).hasPrefix("ask.tool."))
        }
        await #expect(throws: (any Error).self) { try await tools.execute(test, conversationId: "c") }
        let binding = try await tools.approvalBinding(for: test, conversationId: "c")
        #expect(!binding.allowsReuse)
        _ = session.submit(proposal(session, script: "print new"))
        await #expect(throws: (any Error).self) {
            try await tools.executeApproved(test, conversationId: "c", binding: binding, authorize: {})
        }
        let fresh = try await tools.approvalBinding(for: test, conversationId: "c")
        session.tester.searchPath = { "/bin:/usr/bin" }
        let result = try await tools.executeApproved(test, conversationId: "c", binding: fresh, authorize: {})
        #expect(!result.isError && session.lastTestResult?.stdout == "new\n")
        let save = try await tools.execute(call("workflow_save"), conversationId: "c")
        #expect(save.content.contains("Not saved") && fixture.store.workflows.isEmpty)
        _ = try session.save()
        let savedRead = try await tools.execute(read, conversationId: "c")
        let savedState = try JSONSerialization.jsonObject(with: Data(savedRead.content.utf8)) as? [String: Any]
        #expect(savedState?["isNew"] as? Bool == false)
        #expect(savedState?["hasUnsavedChanges"] as? Bool == false)
        #expect(try await tools.execute(call("workflow_list"), conversationId: "c").content.contains("local.unique-lines"))
        #expect(try await tools.execute(read, conversationId: "another").isError)
        fixture.settings.askDisabledSkills.insert(AskWorkflowAuthorSkill.name)
        #expect(!tools.workflowAuthoringEnabled)
        await #expect(throws: (any Error).self) { try await tools.execute(read, conversationId: "c") }
        await #expect(throws: (any Error).self) { try await tools.approvalBinding(for: test, conversationId: "c") }
        session.close()
    }

    @Test func timeoutAndTruncationAreFailuresAndActionsStayPreviewOnly() async throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Tool", workflowID: nil)
        defer { session.close() }
        var object = AskWorkflowFixture.inline(session.draft.manifest!.id, keyword: "wfchat", script: "sleep 5")
        object["run"] = ["mode": "onSubmit", "timeoutSeconds": 1]
        _ = session.submit(.init(summary: "Slow", manifestText: AskWorkflowDraft.format(object), files: [:], deletes: []))
        session.tester.searchPath = { "/bin:/usr/bin" }
        let result = try #require(await session.testLatestProposal([.init(query: "")])?.first)
        #expect(result.timedOut && !result.succeeded)
        var truncated = AskWorkflowTestResult(input: .init(query: ""), exitCode: 0, stdout: "partial", stderr: "", duration: 0)
        truncated.truncated = true
        #expect(!truncated.succeeded && truncated.takesFailureActions)
        object["command"] = ["runtime": "zsh", "inline": "print hello"]
        object["output"] = ["display": "none", "onSuccess": [["action": "copy", "value": "{output}"]]]
        _ = session.submit(.init(summary: "Copy preview", manifestText: AskWorkflowDraft.format(object), files: [:], deletes: []))
        let actions = try #require(await session.testLatestProposal([.init(query: "")])?.first)
        #expect(actions.succeeded && !actions.actionSteps.isEmpty)
        #expect(actions.actionOutcomes.isEmpty)
    }

    @Test func requiredInputAndCancellationBeforeLaunchNeverRunCode() async throws {
        let fixture = try AskWorkflowFixture()
        let session = try authoring(fixture).start("c", name: "Tool", workflowID: nil)
        defer { session.close() }
        var object = AskWorkflowFixture.inline(session.draft.manifest!.id, keyword: "wfchat", script: "print hello")
        object["input"] = ["argument": "required", "selection": "never"]
        _ = session.submit(.init(summary: "Input", manifestText: AskWorkflowDraft.format(object), files: [:], deletes: []))
        session.tester.runner = AskWorkflowFailingRunner(error: AskLocalError.message("must not launch"))
        let result = try #require(await session.testLatestProposal([.init(query: "")])?.first)
        #expect(result.failure == L("ask.workflow.needsInput"))
        // Cancellation while resolving the interpreter must be checked before spawn.
        session.tester.searchPath = {
            try? await Task.sleep(for: .seconds(2))
            return "/bin:/usr/bin"
        }
        let pending = Task { await session.testLatestProposal([.init(query: "input")]) }
        for _ in 0..<1000 where !session.isRunning { await Task.yield() }
        #expect(session.isRunning)
        session.cancel()
        #expect(await pending.value == nil && session.preview == nil)
    }

    @Test func changedInstalledResourcesBlockTrialAndDeletedFilesSurviveRestore() async throws {
        let fixture = try AskWorkflowFixture()
        let saved = try fixture.store.create(.shellText, name: "Tool", keyword: "wfchat", id: "local.tool", builtIn: [])
        try Data("old".utf8).write(to: saved.folder.appendingPathComponent("remove.txt"))
        fixture.store.reload(); fixture.store.trust(saved.id)
        let registry = authoring(fixture)
        let session = try registry.start("c", name: "", workflowID: saved.id)
        _ = session.submit(.init(summary: "Delete", files: [:], deletes: ["remove.txt"]))
        registry.reset()
        let restored = try #require(registry.session("c"))
        #expect(restored.draft.deletedPaths == ["remove.txt"])
        _ = try restored.save()
        #expect(!FileManager.default.fileExists(atPath: saved.folder.appendingPathComponent("remove.txt").path))
        try Data([0, 1, 2]).write(to: saved.folder.appendingPathComponent("asset.bin"))
        #expect(await restored.testLatestProposal([.init(query: "")]) == nil)
        #expect(restored.message == L("ask.workflow.chat.conflict"))
        restored.close()
    }

    @Test func chatRunUsesWorkflowToolsAndApprovalJournal() async throws {
        let fixture = try AskWorkflowFixture()
        let api = AskTestAPI()
        let tools = AskLocalTools(registry: MCPRegistry(settingsStore: MCPSettingsStore(defaults: fixture.settings.defaults)),
                                  settings: fixture.settings)
        let authoring = authoring(fixture, owner: { "o" })
        tools.workflowAuthoring = authoring
        let model = AskConversationModel(api: api,
            cache: try AskConversationCache(url: fixture.home.appendingPathComponent("chat.sqlite")),
            tools: tools, capture: AskTestCapture(), deviceId: "device",
            modelLibrary: AskModelLibrary(defaults: fixture.settings.defaults, automaticallyLoadsCatalog: false),
            session: { ("o", "token") })
        model.workflowAuthoring = authoring
        defer { model.resetSession() }
        await api.setTool(try call("workflow_start", ["name": "Tool"]))
        let manifest = AskWorkflowFixture.inline("local.tool", keyword: "wfchat", script: "print hello")
        await api.queueFollowUpTools([
            try call("workflow_propose", ["summary": "First", "manifest": manifest]),
            try call("workflow_test", ["inputs": [["query": ""]]])
        ])
        model.launcherDraft.text = "Create a reusable tool"
        model.submitLauncher()
        for _ in 0..<1500 where model.pendingApprovals.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        let id = try #require(model.selectedId)
        #expect(model.pendingApprovals[id]?.function.name == "workflow_test")
        let session = try #require(model.authoringSession)
        #expect(session.lastTestResult == nil && fixture.store.workflows.isEmpty)
        session.tester.searchPath = { "/bin:/usr/bin" }
        model.approve(conversationId: id, allowed: true)
        for _ in 0..<1500 where !model.busyIds.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(model.busyIds.isEmpty && session.lastTestResult?.stdout == "hello\n")
        #expect(await api.results.count == 3)
        #expect(fixture.store.workflows.isEmpty)
        _ = try session.save()
        #expect(fixture.store.workflows.count == 1)
        await model.delete(id)
        #expect(authoring.session(id) == nil)
    }


    @Test func restoredInstalledDraftReloadsStoreAndPersistenceErrorsAreVisible() throws {
        let fixture = try AskWorkflowFixture()
        let registry = authoring(fixture)
        let session = try registry.start("c", name: "Tool", workflowID: nil)
        _ = session.submit(proposal(session))
        _ = try session.save()
        let freshStore = AskWorkflowStore(settings: fixture.settings, root: fixture.root)
        #expect(freshStore.workflows.isEmpty)
        let restoredRegistry = AskWorkflowAuthoringStore(workflows: freshStore, root: registry.root, staging: registry.staging, owner: { "alice" })
        let restored = try #require(restoredRegistry.session("c"))
        #expect(!freshStore.workflows.isEmpty && restored.problems.isEmpty)
        _ = try restored.save()
        try FileManager.default.removeItem(at: registry.root)
        try Data("not a directory".utf8).write(to: registry.root)
        _ = restored.submit(proposal(restored))
        #expect(restored.message != nil)
        #expect(throws: (any Error).self) { try restoredRegistry.start("new", name: "Other", workflowID: nil) }
    }

}
