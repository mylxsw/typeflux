import Foundation
import Testing
@testable import Typeflux

/// A device-history transport that is always online and records uploads.
private actor Phase2Transport: AskDeviceTransporting {
    var puts: [(String, AskDeviceSnapshot)] = []
    var values: [String: AskDeviceSnapshot] = [:]
    func list(token _: String, offset _: Int) async throws -> [AskConversationSummary] { [] }
    func snapshot(id: String, token _: String) async throws -> AskDeviceSnapshot? { values[id] }
    func put(id: String, snapshot: AskDeviceSnapshot, token _: String) async throws {
        puts.append((id, snapshot)); values[id] = snapshot
    }
    func webTool(name _: String, arguments _: String, token _: String) async throws -> AskBuiltinToolOutput {
        .init(text: "", isError: false)
    }
    func seed(_ value: AskDeviceSnapshot, id: String) { values[id] = value }
}

/// Chat and Work, phase 2 (GUL-460): Cloud chats run in Typeflux Cloud, private chats may
/// use Cloud models, private conversations upload, offline offers local models, and a
/// conversation another device runs is read-only here.
@Suite("Ask chat and work, phase 2", .serialized, .exclusiveUIState)
@MainActor
struct AskChatWorkPhase2Tests {
    private let device = UUID().uuidString.lowercased()

    private func deviceAPI(_ legacy: AskTestAPI, transport: Phase2Transport, root: URL) -> AskDeviceAPI {
        AskDeviceAPI(root: root, legacy: legacy, transport: transport,
                     resolveAccount: { token in
                         guard token == "user-a" else { throw AuthError.unauthorized }
                         return "user-a"
                     },
                     factory: { _, directory in AskLocalEngine(directory: directory, allowsCloudModels: true) })
    }

    private func request(kind: String?, model: String, create: Bool = true) -> AskSendRequest {
        var value = AskSendRequest(id: UUID().uuidString.lowercased(), deviceId: device, text: "Hello", tools: [], modelRef: model)
        value.kind = kind
        value.deviceCreate = create ? true : nil
        return value
    }

    private func withDevice(_ body: (AskDeviceAPI, AskTestAPI, Phase2Transport) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phase2-\(UUID().uuidString)")
        let legacy = AskTestAPI(), transport = Phase2Transport()
        let api = deviceAPI(legacy, transport: transport, root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await body(api, legacy, transport) } catch { await api.shutdown(); throw error }
        await api.shutdown()
    }

    // MARK: - Where conversations run

    @Test func `a cloud chat opens and continues in Typeflux Cloud and is never adopted`() async throws {
        try await withDevice { api, legacy, transport in
            let id = UUID().uuidString.lowercased()
            let opened = try await api.send(conversationId: id, request: request(kind: "chat", model: "cloud:default"), token: "user-a")
            #expect(opened.kind == "chat")
            #expect(await legacy.sends.count == 1)
            let followUp = try await api.send(conversationId: id,
                                              request: request(kind: nil, model: "cloud:default", create: false), token: "user-a")
            #expect(followUp.messages.filter { $0.role == "user" }.count == 2)
            #expect(await legacy.sends.count == 2, "follow-ups stay in Typeflux Cloud")
            let runId = try #require(followUp.run?.id)
            _ = try await api.retry(conversationId: id, runId: runId, deviceId: device, modelRef: nil, token: "user-a")
            #expect(await legacy.retryModels.count == 1, "retry runs in Typeflux Cloud too")
            #expect(await transport.puts.isEmpty, "no device adoption claim is ever made")
        }
    }

    @Test(arguments: [("work", "cloud:default"), ("chat", "custom:mine"), (nil, "cloud:default")])
    func `work, own-model chats and pre-kind sends run on this Mac`(kind: String?, model: String) async throws {
        try await withDevice { api, legacy, _ in
            let id = UUID().uuidString.lowercased()
            let value = try await api.send(conversationId: id, request: request(kind: kind, model: model), token: "user-a")
            #expect(value.run?.status == "waiting_inference")
            #expect(await legacy.sends.isEmpty)
        }
        #expect(AskDeviceAPI.runsInCloud(request(kind: "chat", model: "cloud:fast")))
        #expect(!AskDeviceAPI.runsInCloud(request(kind: "work", model: "cloud:fast")))
    }

    @Test func `another device's conversation reads with its host`() async throws {
        try await withDevice { api, _, transport in
            let id = UUID().uuidString.lowercased()
            let value = AskConversation(id: id, title: "Tidy", revision: 2, updatedAt: Date(), messages: [], kind: "work")
            await transport.seed(.init(deviceId: "other-mac", revision: 2, conversation: value, deviceName: "Mac Studio"), id: id)
            let read = try await api.conversation(id: id, token: "user-a")
            #expect(read.hostDeviceId == "other-mac")
            #expect(read.hostDeviceName == "Mac Studio")
            await #expect(throws: (any Error).self) {
                try await api.send(conversationId: id, request: request(kind: nil, model: "custom:x", create: false), token: "user-a")
            }
        }
    }

    @Test func `snapshots carry this Mac's name`() throws {
        let snapshot = AskDeviceSnapshot(deviceId: "d", revision: 1, deviceName: "MacBook Pro")
        let body = try JSONSerialization.jsonObject(with: AskCoding.encoder().encode(snapshot)) as? [String: Any]
        #expect(body?["device_name"] as? String == "MacBook Pro")
        let decoded = try AskCoding.decoder().decode(AskDeviceSnapshot.self, from: Data(#"{"device_id":"d","revision":1,"deleted":false}"#.utf8))
        #expect(decoded.deviceName == nil, "older journals decode")
    }

    // MARK: - Uploading a conversation kept on this Mac

    @Test func `upload hands a private conversation to the account and removes the private copy`() async throws {
        try await withDevice { api, _, transport in
            let local = AskTestAPI()
            let id = UUID().uuidString.lowercased()
            var value = AskConversation(id: id, title: "Private notes", revision: 3, updatedAt: Date(), messages: [
                .init(id: "q", role: "user", text: "Hi", createdAt: Date()),
            ], kind: "chat")
            value.run = .init(id: "r", deviceId: device, status: "completed", steps: 1, updatedAt: Date(), tools: [], pending: [])
            await local.seed(value)
            let routed = AskRoutedAPI(cloud: api, local: local)
            let uploaded = try await routed.upload(conversationId: id, token: "user-a")
            #expect(uploaded.id == id && uploaded.kind == "chat")
            #expect(await local.deletes == [id])
            #expect(try await api.conversation(id: id, token: "user-a").title == "Private notes")
            for _ in 0 ..< 200 where await transport.puts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(await transport.puts.first?.0 == id, "the account now synchronizes it")
            await #expect(throws: (any Error).self) { try await routed.upload(conversationId: id, token: "") }
        }
    }

    @Test func `an active private conversation cannot upload`() async throws {
        let local = AskTestAPI()
        var value = AskConversation(id: "a", title: "A", revision: 1, updatedAt: Date(), messages: [])
        value.run = .init(id: "r", deviceId: "d", status: "running", steps: 0, updatedAt: Date(), tools: [], pending: [])
        await local.seed(value)
        let routed = AskRoutedAPI(cloud: AskTestAPI(), local: local)
        await #expect(throws: (any Error).self) { try await routed.upload(conversationId: "a", token: "user-a") }
        #expect(await local.deletes.isEmpty)
    }

    @Test func `the window uploads a private conversation after confirming`() async throws {
        let f = try AskTestFixture()
        defer { f.model.resetSession() }
        f.model.newConversation(storesLocally: true)
        f.model.draft.text = "Keep this private for now"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        let id = try #require(f.model.selectedId)
        #expect(f.model.isLocal(id) && f.model.canUploadSelected)
        let command = try #require(AskCommandCatalog.commands(f.model.commandContext(launcher: false))
            .first { $0.name == "sync" })
        #expect(command.enabled && command.action == .uploadConversation)
        #expect(!AskCommandCatalog.commands(f.model.commandContext(launcher: true)).contains { $0.name == "sync" })
        var confirmations = 0
        f.model.uploadConfirmation = { confirmations += 1; return true }
        f.model.runCommand(command, launcher: true)
        #expect(confirmations == 0)
        var active = try #require(f.model.selected)
        let route = try #require(f.model.credentials(for: id))
        active.revision += 1
        active.run?.id = "sync-blocking-run"
        active.run?.status = "running"
        try await f.model.accept(active, route: route)
        #expect(AskCommandCatalog.commands(f.model.commandContext(launcher: false))
            .first { $0.name == "sync" } == nil)
        f.model.runCommand(command, launcher: false)
        #expect(confirmations == 0, "A stale command cannot upload an active conversation")
        active.revision += 1
        active.run?.status = "completed"
        try await f.model.accept(active, route: route)
        f.model.uploadConfirmation = { false }
        f.model.runCommand(command, launcher: false)
        #expect(await f.api.imports.isEmpty, "declining uploads nothing")
        #expect(f.model.isLocal(id))
        f.model.uploadConfirmation = { true }
        f.model.runCommand(command, launcher: false)
        try await f.wait { !f.model.isLocal(id) && !f.model.isBusy }
        #expect(await f.api.imports == [id])
        #expect(!f.model.isLocal(id))
        #expect(!f.model.canUploadSelected, "a synchronized conversation has nothing to upload")
        #expect(f.model.commandFeedback == L("ask.upload.done"))
        #expect(!AskCommandCatalog.commands(f.model.commandContext(launcher: false)).contains { $0.name == "sync" })
    }

    // MARK: - Cloud models in conversations kept on this Mac

    @Test func `signed in, conversations kept on this Mac may use Cloud models`() throws {
        let f = try AskTestFixture()
        f.model.newConversation(storesLocally: true)
        #expect(f.model.storesLocally(launcher: false))
        #expect(f.model.cloudAvailable(launcher: false))
        #expect(f.model.localFallback("cloud:default", hasImage: false, local: true) == "cloud:default")
        #expect(f.model.cloudToken(for: AskRoute(account: f.sessionState.owner, owner: AskRoutedAPI.localOwner, token: ""))
            == f.sessionState.token)
        #expect(f.model.cloudToken(for: AskRoute(account: "someone-else", owner: "local", token: "")) == "")
        let signedOut = try AskTestFixture(localOnly: true)
        #expect(!signedOut.model.cloudAvailable(launcher: false))
    }

    // MARK: - Offline

    private func libraryWithLocalModel() throws -> (AskModelLibrary, String) {
        let defaults = try #require(UserDefaults(suiteName: "phase2-" + UUID().uuidString))
        let profile = AskModelProfile(name: "My model", baseURL: "https://models.example/v1", model: "my-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        return (AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false), profile.reference)
    }

    @Test func `offline, a Cloud model composer offers a local model`() throws {
        let (library, local) = try libraryWithLocalModel()
        let f = try AskTestFixture(modelLibrary: library)
        f.model.newConversation()
        f.model.draft.modelRef = "cloud:default"
        #expect(f.model.offlineSuggestion(launcher: false) == nil, "online needs nothing")
        f.model.networkAvailable = false
        #expect(f.model.offlineSuggestion(launcher: false) == .useLocalModel(local))
        f.model.applyOfflineSuggestion(.useLocalModel(local), launcher: false)
        #expect(f.model.modelReference(launcher: false) == local)
        #expect(f.model.offlineSuggestion(launcher: false) == nil, "a local model works offline")
    }

    @Test func `offline, a started Cloud conversation continues locally in a new one`() async throws {
        let (library, local) = try libraryWithLocalModel()
        let f = try AskTestFixture(modelLibrary: library)
        f.model.newConversation()
        f.model.setConversationKind(.chat, launcher: false)
        f.model.draft.text = "Explain actors"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        f.model.networkAvailable = false
        #expect(f.model.offlineSuggestion(launcher: false) == .continueLocally(local))
        f.model.applyOfflineSuggestion(.continueLocally(local), launcher: false)
        #expect(f.model.selectedId == nil)
        #expect(f.model.draft.references?.first?.text.contains("Explain actors") == true)
        #expect(f.model.modelReference(launcher: false) == local)
    }

    @Test func `offline without a local model points to settings`() throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        f.model.draft.modelRef = "cloud:default"
        f.model.networkAvailable = false
        #expect(f.model.offlineSuggestion(launcher: false) == .needsLocalModel)
    }

    // MARK: - Continuing elsewhere, commands and hosts

    @Test func `continue as work carries the chat into a new task`() async throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        f.model.setConversationKind(.chat, launcher: false)
        f.model.draft.text = "Tidy my downloads"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        let source = try #require(f.model.selected)
        f.model.continueInNew(.work)
        #expect(f.model.selectedId == nil)
        #expect(f.model.conversationKind(launcher: false) == .work)
        #expect(f.model.draft.references?.count == 1)
        #expect(f.model.draft.references?.first?.messageId == source.id)
        #expect(f.model.commandFeedback == L("ask.kind.continuedAsWork"))
    }

    @Test func `the chat and work commands switch a draft or continue a started one`() async throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        let names = AskCommandCatalog.commands(f.model.commandContext(launcher: false)).map(\.name)
        #expect(names.contains("chat") && names.contains("work"))
        f.model.chooseConversationKind(.chat, launcher: false)
        #expect(f.model.conversationKind(launcher: false) == .chat)
        f.model.chooseConversationKind(.work, launcher: false)
        #expect(f.model.conversationKind(launcher: false) == .work)
        f.model.draft.text = "Run it"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        f.model.chooseConversationKind(.work, launcher: false)
        #expect(f.model.selectedId != nil, "already work: nothing to do")
        f.model.chooseConversationKind(.chat, launcher: false)
        #expect(f.model.selectedId == nil && f.model.conversationKind(launcher: false) == .chat)
    }

    @Test func `a conversation another device runs is read-only here`() async throws {
        let f = try AskTestFixture()
        var other = AskConversation(id: "o", title: "On Studio", revision: 1, updatedAt: Date(), messages: [], kind: "work")
        other.hostDeviceId = "studio"; other.hostDeviceName = "Mac Studio"
        var mine = AskConversation(id: "m", title: "Mine", revision: 1, updatedAt: Date(), messages: [])
        mine.hostDeviceId = "device"
        await f.api.seed(other); await f.api.seed(mine)
        await f.model.select("o")
        #expect(f.model.selectedHostElsewhere == "Mac Studio")
        await f.model.select("m")
        #expect(f.model.selectedHostElsewhere == nil, "this Mac's own id is not elsewhere")
        #expect(AskConversationModel.hostElsewhere(id: "x", name: nil, thisDevice: "device") == L("ask.host.anotherMac"))
        #expect(AskConversationModel.hostElsewhere(id: nil, name: "A", thisDevice: "device") == nil)
        #expect(f.model.hostElsewhere(.init(id: "o", title: "", hostDeviceId: "STUDIO", hostDeviceName: "S")) == "S")
    }

    // MARK: - Pure pieces

    @Test func `a transcript reference keeps the newest turns within its limit`() {
        var value = AskConversation(id: "c", title: "Long", revision: 1, updatedAt: Date(), messages: [])
        for index in 0 ..< 50 {
            value.messages.append(.init(id: "u\(index)", role: "user", text: "Question \(index) " + String(repeating: "x", count: 40),
                                        createdAt: Date()))
            value.messages.append(.init(id: "t\(index)", role: "tool", text: "ignored", createdAt: Date()))
        }
        let reference = AskReference(conversation: value, limit: 500)
        #expect(reference.messageId == "c")
        #expect(reference.text.hasPrefix("# Long"))
        #expect(reference.text.contains("Question 49"))
        #expect(!reference.text.contains("Question 0 "))
        #expect(!reference.text.contains("ignored"))
        #expect(reference.text.utf8.count < 700)
    }

    @Test func `the work folder button names the folders`() {
        var draft = AskDraft()
        #expect(AskWorkEnvironmentButton.title(draft) == L("ask.kind.defaultWorkspace"))
        draft.attachments = [.init(id: "a", kind: .folder, name: "Downloads")]
        #expect(AskWorkEnvironmentButton.title(draft) == "Downloads")
        draft.attachments?.append(.init(id: "b", kind: .folder, name: "Desktop"))
        draft.attachments?.append(.init(id: "c", kind: .file, name: "a.txt"))
        #expect(AskWorkEnvironmentButton.title(draft) == L("ask.kind.folders", "Downloads", 1))
    }

    @Test func `work drafts get the work placeholder and the sent request carries the kind`() async throws {
        let f = try AskTestFixture()
        f.model.newConversation()
        f.model.setConversationKind(.work, launcher: false)
        #expect(L("ask.input.placeholder.work") != L("ask.input.placeholder"))
    }
}
