import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite("Notebook agent tool and skill", .exclusiveUIState)
@MainActor
struct AskNotebookToolTests {
    private func tool(_ store: SQLiteAskNoteStore, hidden: [String] = ["私密"]) -> AskNotebookTool {
        AskNotebookTool(store: store, hiddenTags: hidden, clock: { Date(timeIntervalSince1970: 9000) })
    }

    private func seeded() -> (SQLiteAskNoteStore, AskNote, AskNote, AskNote) {
        let store = makeTestNotes()
        let index = makeTestNote("Postgres 向量索引", body: "## 结论\n选 HNSW。\n\n## 参数\nm = 16, ef_construction = 64\n",
                                 tags: ["数据库"], at: 300)
        let other = makeTestNote("pgvector notes", body: "IVFFlat needs data before indexing", at: 200)
        let secret = makeTestNote("Secret HNSW", body: "password hunter2", tags: ["私密"], at: 400)
        [index, other, secret].forEach { store.save($0) }
        return (store, index, other, secret)
    }

    @Test func describesItselfAndItsRisks() throws {
        let definition = AskNotebookTool.definition
        #expect(definition.name == "notebook")
        let schema = try #require(try JSONSerialization.jsonObject(with: definition.parameters.data) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect((action["enum"] as? [String])?.count == 8)
        #expect(AskNotebookTool.risk(action: "search") == .read && AskNotebookTool.risk(action: "append") == .write)
        #expect(AskNotebookTool.risk(action: "delete") == .write)
        #expect(AskNotebookSkill.skill.name == "notebook" && AskNotebookSkill.body.contains("“Note title › Heading”"))
        #expect(AskBuiltinSkills.all.contains { $0.name == AskNotebookSkill.name })
        #expect(AskNotebookSkill.skill.displayDescription == L("ask.skill.notebook.description"))
    }

    @Test func searchesReadsAndListsVisibleNotes() throws {
        let (store, index, other, secret) = seeded()
        let notebook = tool(store)
        let found = notebook.searchNotes("HNSW ef_construction", limit: 8)
        #expect(found.map(\.note.id) == [index.id] && found.first?.hits == 2, "the hidden note is left out")
        #expect(notebook.searchNotes("数据库", limit: 8).map(\.note.id) == [index.id], "tags match too")
        #expect(notebook.searchNotes("", limit: 1).map(\.note.id) == [index.id])
        let text = try notebook.execute(["action": "search", "query": "IVFFlat", "limit": 99])
        #expect(text.hasPrefix("1 note(s):") && text.contains(other.id.uuidString) && text.contains("IVFFlat needs"))
        #expect(try notebook.execute(["action": "search", "query": "nothing-here"]).hasPrefix("No notes matched"))

        let read = try notebook.execute(["action": "read", "id": index.id.uuidString])
        #expect(read.contains("title: Postgres 向量索引") && read.contains("tags: 数据库") && read.contains("## 参数"))
        let section = try notebook.execute(["action": "read", "id": index.id.uuidString, "heading": "参数"])
        #expect(section.contains("ef_construction") && !section.contains("选 HNSW"))
        #expect(try notebook.execute(["action": "read", "id": index.id.uuidString, "heading": "x"]).contains("Headings: 结论 | 参数"))
        var long = makeTestNote("Long", body: String(repeating: "长", count: 9000))
        long.tags = []
        store.save(long)
        let page = try notebook.execute(["action": "read", "id": long.id.uuidString, "limit": 500])
        #expect(page.contains("read again with offset 500 of 9000"))
        let last = try notebook.execute(["action": "read", "id": long.id.uuidString, "offset": 8800])
        #expect(!last.contains("read again"))
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "read", "id": secret.id.uuidString]) }
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "read", "id": "nope"]) }
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "fly"]) }

        let tags = try notebook.execute(["action": "list", "scope": "tags"])
        #expect(tags == "#数据库 (1)", "hidden tags are not listed")
        #expect(try notebook.execute(["action": "list", "scope": "pinned"]) == "No notes.")
        #expect(try notebook.execute(["action": "list", "scope": "tag:数据库"]).contains(index.id.uuidString))
        #expect(!(try notebook.execute(["action": "list"])).contains(secret.id.uuidString))
        #expect(try tool(makeTestNotes()).execute(["action": "list", "scope": "tags"]) == "No tags yet.")
        #expect(AskNotebookTool.snippet(other, query: "before").hasPrefix("IVFFlat needs data before"))
    }

    @Test func writesKeepRevisionsAndMarkTheAgent() throws {
        let (store, index, _, secret) = seeded()
        let notebook = tool(store)
        let created = try notebook.execute(["action": "create", "body": "## Plan\n- a", "tags": ["#x", "x", "y"]])
        let id = try #require(UUID(uuidString: String(created.split(separator: " ")[2])))
        let note = try #require(store.note(id: id))
        #expect(note.title == "Plan" && note.tags == ["x", "y"] && note.author == .agent && note.source == .manual)
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "create", "body": " "]) }

        let appended = try notebook.execute(["action": "append", "id": index.id.uuidString, "body": "- 压测", "heading": "结论"])
        #expect(appended.contains("under \"结论\""))
        let changed = try #require(store.note(id: index.id))
        #expect(changed.body.contains("选 HNSW。\n\n- 压测\n\n## 参数") && changed.author == .agent)
        #expect(changed.originalBody == index.body && store.revisions(of: index.id).first?.body == index.body)
        #expect(try notebook.execute(["action": "append", "id": index.id.uuidString, "body": "tail", "heading": "nope"])
            .contains("no heading"))
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "append", "id": index.id.uuidString, "body": ""]) }

        _ = try notebook.execute(["action": "update", "id": index.id.uuidString, "find": "m = 16", "replace": "m = 24",
                                  "title": "Postgres HNSW"])
        #expect(store.note(id: index.id)?.body.contains("m = 24") == true && store.note(id: index.id)?.title == "Postgres HNSW")
        #expect(throws: AskLocalError.self) {
            try notebook.execute(["action": "update", "id": index.id.uuidString, "find": "missing", "replace": "x"])
        }
        _ = try notebook.execute(["action": "update", "id": index.id.uuidString, "body": "a a"])
        #expect(throws: AskLocalError.self) {
            try notebook.execute(["action": "update", "id": index.id.uuidString, "find": "a", "replace": "b"])
        }
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "update", "id": index.id.uuidString]) }
        let revisions = store.revisions(of: index.id).count
        _ = try notebook.execute(["action": "update", "id": index.id.uuidString, "body": "a a"])
        #expect(store.revisions(of: index.id).count == revisions, "an unchanged note keeps no revision")

        let tagged = try notebook.execute(["action": "tag", "id": index.id.uuidString, "add": ["新"], "remove": ["数据库"], "pin": true])
        #expect(tagged.contains("#新") && tagged.contains("pinned") && store.note(id: index.id)?.pinned == true)
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "tag", "id": index.id.uuidString]) }

        let deleted = try notebook.execute(["action": "delete", "id": index.id.uuidString])
        #expect(deleted.contains("Recently Deleted") && store.note(id: index.id)?.isDeleted == true)
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "delete", "id": index.id.uuidString]) }
        #expect(throws: AskLocalError.self) { try notebook.execute(["action": "update", "id": secret.id.uuidString, "body": "x"]) }
        var huge = makeTestNote("Huge", body: String(repeating: "x", count: 20000))
        huge.tags = []
        store.save(huge)
        let clipped = try AskNotebookTool(store: store, hiddenTags: []).execute(["action": "read", "id": huge.id.uuidString])
        #expect(clipped.count <= AskNotebookTool.outputLimit + 2)
    }

    @Test func theLocalToolsOfferTheNotebook() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-tools-\(UUID().uuidString)")
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "notebook-tools-\(UUID().uuidString)")!)
        let registry = MCPRegistry(settingsStore: MCPSettingsStore(defaults: UserDefaults(suiteName: "nb-mcp-\(UUID().uuidString)")!))
        let tools = AskLocalTools(registry: registry, settings: settings, skills: AskSkillLibrary(userDirectory: root),
                                  notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("m.json")), owner: { "o" })
        tools.runningBundleIdentifiers = { [] }
        var names = await tools.definitions(conversationId: nil).map(\.name)
        #expect(!names.contains("notebook") && !tools.enabledSkills.contains { $0.name == "notebook" })
        let (store, index, _, _) = seeded()
        tools.notebook = store
        names = await tools.definitions(conversationId: nil).map(\.name)
        #expect(names.contains("notebook") && tools.enabledSkills.contains { $0.name == "notebook" })
        let search = AskToolCall(id: "1", function: .init(name: "notebook", arguments: #"{"action":"search","query":"HNSW"}"#))
        let append = AskToolCall(id: "2", function: .init(name: "notebook",
                                                         arguments: #"{"action":"append","id":"\#(index.id.uuidString)","body":"more"}"#))
        #expect(tools.risk(of: search) == .read && tools.risk(of: append) == .write)
        let output = try await tools.execute(search, conversationId: "c")
        #expect(output.content.contains(index.id.uuidString))
        let readBinding = try await tools.approvalBinding(for: search, conversationId: "c")
        let writeBinding = try await tools.approvalBinding(for: append, conversationId: "c")
        #expect(readBinding.allowsReuse && !writeBinding.allowsReuse)
        #expect(writeBinding.summary.contains("append"))
        #expect(AskApprovalPresentation.preview(append) == .content("more"))
        let replace = AskToolCall(id: "3", function: .init(name: "notebook",
                                                          arguments: #"{"action":"update","id":"x","find":"a","replace":"b"}"#))
        #expect(AskApprovalPresentation.preview(replace) == .diff(removed: "a", added: "b"))
        #expect(AskTheme.toolTitle(search) == L("ask.tool.notebook") + " · " + L("ask.notebook.action.search") + " · HNSW")
        #expect(AskPresentation.toolSymbol(search) == "note.text")

        settings.askDisabledSkills = ["notebook"]
        names = await tools.definitions(conversationId: nil).map(\.name)
        #expect(!names.contains("notebook"), "turning the skill off removes the tool")
        settings.askDisabledSkills = []
        settings.askNotebookAgentEnabled = false
        names = await tools.definitions(conversationId: nil).map(\.name)
        #expect(!names.contains("notebook"))
        await #expect(throws: AskLocalError.self) { _ = try await tools.execute(search, conversationId: "c") }
        await #expect(throws: AskLocalError.self) { _ = try await tools.approvalBinding(for: search, conversationId: "c") }
        settings.askNotebookAgentEnabled = true
        settings.askNotebookHiddenTags = ["数据库"]
        #expect(!(try await tools.execute(search, conversationId: "c")).content.contains(index.id.uuidString))
    }
}

@Suite("Saving answers and new notes from the launcher", .exclusiveUIState)
@MainActor
struct AskNotebookEntryTests {
    @Test func answersSaveToTheNotebookAndCanBeTakenOut() async throws {
        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        let model = fixture.model
        let store = makeTestNotes()
        model.notes = store
        let question = AskMessage(id: "q", role: "user", text: "HNSW 还是 IVFFlat？", createdAt: Date())
        let answer = AskMessage(id: "a", role: "assistant", text: "选 **HNSW**。", createdAt: Date())
        await fixture.api.seed(AskConversation(id: "conv", title: "Index", revision: 1, updatedAt: Date(),
                                               messages: [question, answer]))
        await model.select("conv")
        #expect(model.question(before: answer) == "HNSW 还是 IVFFlat？")
        #expect(model.question(before: AskMessage(id: "x", role: "assistant", text: "", createdAt: Date())).isEmpty)
        model.toggleAnswerNote(answer)
        let note = try #require(store.list(AskNoteQuery()).first)
        #expect(note.source == .chat && note.conversationID == "conv" && note.messageID == "a" && note.input == question.text)
        #expect(note.title == "HNSW 还是 IVFFlat？" && model.answerNoteIDs["a"] == note.id)
        #expect(model.commandFeedback == L("ask.notes.saved"))
        model.toggleAnswerNote(answer, excerpt: "  HNSW ")
        #expect(store.count(.all) == 2 && model.answerNoteIDs["a"] == note.id, "a selection is a note of its own")
        model.toggleAnswerNote(answer)
        #expect(store.note(id: note.id)?.isDeleted == true && model.answerNoteIDs["a"] == nil && model.commandFeedback == L("ask.notes.removed"))
        model.toggleAnswerNote(answer)
        var edited = try #require(store.list(AskNoteQuery(scope: .source(.chat))).first { $0.messageID == "a" })
        edited.editedAt = Date()
        store.save(edited)
        model.answerNoteIDs = [:]
        model.refreshAnswerNotes()
        #expect(model.answerNoteIDs["a"] == edited.id)
        model.toggleAnswerNote(answer)
        #expect(store.note(id: edited.id) != nil && model.commandFeedback == L("ask.notes.editedKept"))
        model.toggleAnswerNote(AskMessage(id: "e", role: "assistant", text: " ", createdAt: Date()))
        #expect(store.count(.all) == 2)
        model.notes = nil
        model.refreshAnswerNotes()
        #expect(model.answerNoteIDs.isEmpty)
    }

    @Test func theNbKeywordOffersANewNote() async throws {
        let store = makeTestNotes()
        let plugin = AskNotesPlugin(store: store)
        let request = AskPluginRequest(text: "购物清单", origin: .argument, keyword: AskNotesPlugin.keywords[0],
                                       options: [:], interfaceLanguage: .english)
        let output = try await plugin.run(request, plan: plugin.plan(request))
        let row = try #require(output.items.first { $0.id == AskNotesPlugin.newNoteItemID })
        #expect(row.title == L("ask.notes.newTitled", "购物清单") && row.actions.first?.kind == .createNote("购物清单"))
        let empty = AskPluginRequest(text: "", origin: .argument, keyword: AskNotesPlugin.keywords[0], options: [:],
                                     interfaceLanguage: .english)
        let list = try await plugin.run(empty, plan: plugin.plan(empty))
        #expect(!list.items.contains { $0.id == AskNotesPlugin.newNoteItemID })

        let fixture = try AskTestFixture()
        defer { fixture.model.resetSession() }
        var created: [String] = []
        fixture.model.createNote = { created.append($0) }
        #expect(fixture.model.performPluginAction(.init(kind: .createNote("购物清单"), title: "", symbol: "")) == .close)
        #expect(created == ["购物清单"])
        #expect(AskSelectionAction.standard == [.explain, .translate, .ask, .copy])
        #expect(AskSelectionAction.note.title == L("ask.notes.saveSelection") && AskSelectionAction.note.question.isEmpty)
        #expect(AskSelectionAction.note.systemImage == "note.text.badge.plus")
    }
}
