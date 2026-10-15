import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite("Conversation workspace service wiring", .serialized, .exclusiveUIState)
struct AskConversationWindowServicesTests {
    @Test func `launcher opens when conversation storage cannot be opened`() async throws {
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try Fixture(settings)
            do {
                let unavailable = RecoveringAskConversationCache(factory: { throw CocoaError(.fileReadNoPermission) })
                let controller = try fixture.makeController(settings, cache: unavailable)
                fixture.controller = controller
                controller.showLauncher()
                #expect(controller.launcherWindow?.isVisible == true)
                controller.model.launcherDraft.text = "search remains usable"
                #expect(controller.model.launcherDraft.text == "search remains usable")
                await #expect(throws: (any Error).self) { _ = try await unavailable.list(owner: "owner") }
                #expect(controller.launcherWindow?.isVisible == true)
                await unavailable.shutdown()
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }

    @Test func `workspace callbacks persist notes and navigate to the owned windows`() async throws {
        weak var releasedResults: AskResultWindowController?
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try Fixture(settings)
            releasedResults = fixture.results
            do {
                let controller = try fixture.makeController(settings)
                fixture.controller = controller
                for task in controller.maintenanceTasks {
                    await task.value
                }
                #expect(controller.model.workflows === fixture.workflows)
                #expect(controller.model.workflowAuthoring === fixture.tools.workflowAuthoring)
                #expect(fixture.tools.notebook === fixture.notes)
                // The callback installed by the production initializer opens and reuses
                // this controller's conversation window, with its isolated cache.
                controller.model.onShowConversation?()
                await controller.conversationRefreshTask?.value
                let conversation = try #require(controller.conversationWindow)
                #expect(conversation.isVisible)
                controller.model.draft.text = "Keep the workspace draft."
                controller.model.onShowConversation?()
                await controller.conversationRefreshTask?.value
                #expect(controller.conversationWindow === conversation)
                #expect(controller.model.draft.text == "Keep the workspace draft.")
                try await checkNotes(fixture)
                try checkWordBook(fixture, settings)
                #expect(!fixture.results.services.isRunning("invalid.fixture.application"))
                #expect(await fixture.results.services.insert("fixture text", nil) == false)
                #expect(await fixture.results.services.insert("fixture text", "invalid.fixture.application") == false)
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
        #expect(releasedResults == nil, "The result-window observer must not retain a closed workspace")
    }

    private func checkNotes(_ fixture: Fixture) async throws {
        let services = fixture.results.services
        let draft = AskNoteDraft(command: "Explain", keyword: "ex", input: "Fixture concept",
                                 body: "A controlled result", model: nil, sourceApp: nil, sourceBundleID: nil)
        let id = try #require(services.saveNote(draft))
        #expect(services.noteExists(id))
        var note = try #require(fixture.notes.note(id: id))
        #expect(note.body == draft.body)
        let document = AskResultDocument(note: note, services: services)
        defer { document.close() }
        document.openNotes()
        let window = try #require(fixture.notesWindow.window)
        try await SettingsBehaviorTestSupport.wait { window.isVisible && fixture.notesWindow.model?.selectedID == id }
        #expect(fixture.notesWindow.model?.selected?.body == draft.body)
        let controller = try #require(fixture.controller)
        fixture.notesWindow.model?.askAIAboutSelected()
        try await SettingsBehaviorTestSupport.wait { controller.model.draft.references?.first?.noteId == id }
        #expect(controller.conversationWindow?.isVisible == true)
        #expect(controller.model.selectedId == nil && controller.model.draft.text.isEmpty)
        #expect(!controller.model.draft.canSend)
        #expect(await fixture.api.sends.isEmpty)
        #expect(controller.model.savedChatDrafts.contains { $0.draft.text == "Keep the workspace draft." })
        note.editedAt = Date()
        #expect(fixture.notes.save(note))
        #expect(!services.removeNote(id), "An edited note must survive unstar from its original result")
        note.editedAt = nil
        #expect(fixture.notes.save(note))
        #expect(services.removeNote(id))
        #expect(!services.noteExists(id))
        #expect(fixture.notes.note(id: id)?.isDeleted == true)
        #expect(fixture.notes.count(.trash) == 1, "result-window unstar remains recoverable")
        #expect(!services.removeNote(id))
    }

    private func checkWordBook(_ fixture: Fixture, _ settings: SettingsStore) throws {
        let recorder = try #require(fixture.controller?.model.wordBook)
        let lookup = AskWordBookLookup(headword: "fixture", source: "en", target: "zh", card: nil,
                                       translation: "controlled translation", model: nil)
        settings.askWordBookRecordsHistory = false
        recorder.record(lookup)
        #expect(fixture.wordBook.entry(forKey: lookup.key) == nil)
        settings.askWordBookRecordsHistory = true
        recorder.record(lookup)
        #expect(fixture.wordBook.entry(forKey: lookup.key)?.headword == "fixture")
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let name = "WorkspaceServices-" + UUID().uuidString
        let cache: AskConversationCache
        let api = AskTestAPI()
        let tools: AskLocalTools
        let workflows: AskWorkflowStore
        let wordBook: SQLiteAskWordBookStore
        let notes: SQLiteAskNoteStore
        let wordBookWindow = AskWordBookWindowController()
        let notesWindow = AskNotesWindowController()
        let results = AskResultWindowController()
        let policy = AskConversationWindowLifecycleTests.Policy()
        var controller: AskConversationWindowController?
        private let oldNotesFrame: Any?

        init(_ settings: SettingsStore) throws {
            oldNotesFrame = UserDefaults.standard.object(forKey: "NSWindow Frame AskNotes.v2")
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("workspace-services-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                cache = try AskConversationCache(url: root.appendingPathComponent("conversations.sqlite"))
                wordBook = SQLiteAskWordBookStore(url: root.appendingPathComponent("words.sqlite"))
                notes = SQLiteAskNoteStore(url: root.appendingPathComponent("notes.sqlite"))
                workflows = AskWorkflowStore(settings: settings, root: root.appendingPathComponent("workflows"))
                tools = AskLocalTools(registry: MCPRegistry(), settings: settings,
                                      sandbox: AskCodeSandbox(baseDirectory: root.appendingPathComponent("sandbox")),
                                      notes: AskMemoryNoteStore(fileURL: root.appendingPathComponent("memory.json")))
                results.defaults = settings.defaults
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func makeController(_ settings: SettingsStore,
                            cache override: (any AskCaching)? = nil) throws -> AskConversationWindowController {
            try AskConversationWindowController(
                settings: settings, injector: ContextTextInjector(), registry: MCPRegistry(),
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false),
                dockVisibility: DockVisibilityController(app: policy),
                services: .init(tools: tools, cache: override ?? cache, api: api, capture: AskTestCapture(),
                                session: { ("workspace-fixture", "fixture-token") }, workflows: workflows,
                                wordBook: wordBook, notes: notes, wordBookWindow: wordBookWindow,
                                notesWindow: notesWindow, resultWindow: results, frameAutosaveName: name)
            )
        }

        func close() async {
            if let controller {
                for task in controller.maintenanceTasks {
                    task.cancel(); await task.value
                }
                controller.conversationRefreshTask?.cancel()
                await controller.conversationRefreshTask?.value
                controller.dismissLauncher()
                controller.model.resetSession()
            }
            for window in [controller?.conversationWindow, controller?.controlWindow,
                           notesWindow.window, wordBookWindow.window].compactMap(\.self) {
                DockVisibilityController.shared.windowDidHide(window)
                window.delegate = nil
                window.setFrameAutosaveName("")
                window.contentView = nil
                window.orderOut(nil)
                window.close()
                #expect(!window.isVisible)
            }
            NSWindow.removeFrame(usingName: name)
            NSWindow.removeFrame(usingName: "AskNotes.v2")
            if let oldNotesFrame {
                UserDefaults.standard.set(oldNotesFrame, forKey: "NSWindow Frame AskNotes.v2")
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
