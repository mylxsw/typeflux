import AppKit
import Testing
@testable import Typeflux

@MainActor
@Suite("Conversation workspace service wiring", .serialized, .exclusiveUIState)
struct AskConversationWindowServicesTests {
    @Test func workspaceCallbacksPersistNotesAndNavigateToTheOwnedWindows() async throws {
        weak var releasedResults: AskResultWindowController?
        try await SettingsBehaviorTestSupport.withFixture { settings in
            let fixture = try Fixture(settings)
            releasedResults = fixture.results
            do {
                let controller = try fixture.makeController(settings)
                fixture.controller = controller
                for task in controller.maintenanceTasks { await task.value }
                #expect(controller.model.workflows === fixture.workflows)
                #expect(controller.model.workflowAuthoring === fixture.tools.workflowAuthoring)
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
        note.editedAt = Date()
        #expect(fixture.notes.save(note))
        #expect(!services.removeNote(id), "An edited note must survive unstar from its original result")
        note.editedAt = nil
        #expect(fixture.notes.save(note))
        #expect(services.removeNote(id))
        #expect(!services.noteExists(id))
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
            oldNotesFrame = UserDefaults.standard.object(forKey: "NSWindow Frame AskNotes")
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

        func makeController(_ settings: SettingsStore) throws -> AskConversationWindowController {
            try AskConversationWindowController(
                settings: settings, injector: ContextTextInjector(), registry: MCPRegistry(),
                modelLibrary: AskModelLibrary(defaults: settings.defaults, automaticallyLoadsCatalog: false),
                dockVisibility: DockVisibilityController(app: policy),
                services: .init(tools: tools, cache: cache, api: api, capture: AskTestCapture(),
                                session: { ("workspace-fixture", "fixture-token") }, workflows: workflows,
                                wordBook: wordBook, notes: notes, wordBookWindow: wordBookWindow,
                                notesWindow: notesWindow, resultWindow: results, frameAutosaveName: name)
            )
        }

        func close() async {
            if let controller {
                for task in controller.maintenanceTasks { task.cancel(); await task.value }
                controller.conversationRefreshTask?.cancel()
                await controller.conversationRefreshTask?.value
                controller.dismissLauncher()
                controller.model.resetSession()
            }
            for window in [controller?.conversationWindow, controller?.controlWindow,
                           notesWindow.window, wordBookWindow.window].compactMap({ $0 }) {
                DockVisibilityController.shared.windowDidHide(window)
                window.delegate = nil
                window.setFrameAutosaveName("")
                window.contentView = nil
                window.orderOut(nil)
                window.close()
                #expect(!window.isVisible)
            }
            NSWindow.removeFrame(usingName: name)
            NSWindow.removeFrame(usingName: "AskNotes")
            if let oldNotesFrame { UserDefaults.standard.set(oldNotesFrame, forKey: "NSWindow Frame AskNotes") }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
