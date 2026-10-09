import AppKit
import SwiftUI
import Testing
@testable import Typeflux

private actor PreflightCatalog: ProviderModelCatalog {
    var fails = false
    var held = false
    var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func configure(fails: Bool = false, held: Bool = false) { self.fails = fails; self.held = held }
    func release() { held = false; continuation?.resume(); continuation = nil }
    func models(provider: RegisteredProvider, connection: SettingsStore.TextLLMConfiguration) async throws -> [RegisteredModel] {
        calls += 1
        if held { await withCheckedContinuation { continuation = $0 } }
        if fails { throw AskLocalError.message("Offline") }
        return [.init(id: "fixture", name: "Fixture")]
    }
}

@Suite("Ask submission preflight", .serialized)
@MainActor
struct AskSubmissionPreflightTests {
    private func makeFixture(catalog: PreflightCatalog? = nil, local: Bool = true) throws -> AskTestFixture {
        let defaults = try #require(UserDefaults(suiteName: "ask-preflight-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false,
                                      catalog: catalog ?? PreflightCatalog())
        if catalog != nil {
            var registry = library.registry
            if let index = registry.providers.firstIndex(where: \.isOllama) { registry.providers[index].models = [] }
            try library.commit(registry)
            try library.addModels([.init(id: "fixture", name: "Fixture", reference: "custom:fixture")], providerID: "ollama")
            library.ollamaAvailable = true
        }
        return try AskTestFixture(localOnly: local, modelLibrary: library)
    }

    private func assertNoConversation(_ fixture: AskTestFixture, original: AskDraft, launcher: Bool) async throws {
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.selectedId == nil)
        #expect(fixture.model.conversations.isEmpty && fixture.model.snapshots.isEmpty && fixture.model.localConversationIds.isEmpty)
        #expect(fixture.tools.bound.isEmpty)
        #expect((launcher ? fixture.model.launcherDraft : fixture.model.draft) == original)
        #expect(await fixture.api.sends.isEmpty)
        #expect(try await fixture.cache.list(owner: fixture.model.owner).isEmpty)
        #expect(try await fixture.cache.list(owner: AskRoutedAPI.localOwner).isEmpty)
        #expect(fixture.model.submissionIssues[launcher] != nil)
    }

    @Test(arguments: [true, false])
    func noOwnModelPreservesDraftAndOffersWorkingActions(launcher: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.model.resetSession() }
        let original = AskDraft(text: "  Keep every word\n", includeScreenshot: false, selection: "Selection", source: "Safari")
        var shown = 0
        fixture.model.onShowConversation = { shown += 1 }
        if launcher { fixture.model.launcherDraft = original; fixture.model.submitLauncher() }
        else { fixture.model.draft = original; fixture.model.submitDraft() }
        try await assertNoConversation(fixture, original: original, launcher: launcher)
        let issue = try #require(fixture.model.submissionIssues[launcher])
        #expect(issue.offersModels && issue.offersSignIn)
        #expect(issue.errorDescription == L("ask.local.modelRequired"))
        #expect(shown == 0)
        if launcher {
            try await Task.sleep(for: .milliseconds(350))
            #expect(try await fixture.cache.draft(key: "launcher", owner: fixture.model.owner) == original)
        }
    }

    @Test(arguments: ["text", "selection", "source", "references", "payload"])
    func inputLimitsNeverCreateAConversation(field: String) async throws {
        let fixture = try makeFixture(local: false)
        defer { fixture.model.resetSession() }
        var original = AskDraft(text: "Keep me", includeScreenshot: false)
        switch field {
        case "text": original.text = String(repeating: "x", count: 32001)
        case "selection": original.selection = String(repeating: "x", count: 64001)
        case "source": original.source = String(repeating: "x", count: 1001)
        case "references": original.references = (0..<33).map { .init(messageId: String($0), text: "ref") }
        default: original.attachments = [.init(kind: .file, name: "large", text: String(repeating: "x", count: 4_000_001))]
        }
        fixture.model.launcherDraft = original
        fixture.model.submitLauncher()
        try await assertNoConversation(fixture, original: original, launcher: true)
        #expect(fixture.model.submissionIssues[true]?.offersModels == false)
    }

    @Test(arguments: ["custom:missing", "cloud:removed"])
    func missingModelNeverWritesAnUnsentSnapshot(reference: String) async throws {
        let fixture = try makeFixture(local: false)
        defer { fixture.model.resetSession() }
        let original = AskDraft(text: "Keep me", includeScreenshot: false, modelRef: reference)
        fixture.model.draft = original
        fixture.model.submitDraft()
        try await assertNoConversation(fixture, original: original, launcher: false)
        #expect(fixture.model.submissionIssues[false]?.offersModels == true)
    }

    @Test func catalogFailureKeepsTheLauncherAndCanBeCorrected() async throws {
        let fixture = try makeFixture(local: false)
        defer { fixture.model.resetSession() }
        await fixture.api.setFailModels(true)
        let original = AskDraft(text: "Keep me", includeScreenshot: false, modelRef: "cloud:chosen")
        fixture.model.launcherDraft = original
        fixture.model.submitLauncher()
        try await assertNoConversation(fixture, original: original, launcher: true)
        await fixture.api.setFailModels(false)
        await fixture.api.setCloudModels([.init(id: "chosen", name: "Chosen")])
        fixture.model.submitLauncher()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.count == 1)
        #expect(fixture.model.submissionIssues[true] == nil)
    }

    @Test func ollamaProbeFailureLeavesNoConversation() async throws {
        let catalog = PreflightCatalog()
        await catalog.configure(fails: true)
        let fixture = try makeFixture(catalog: catalog)
        defer { fixture.model.resetSession() }
        let original = AskDraft(text: "Keep me", includeScreenshot: false)
        fixture.model.launcherDraft = original
        fixture.model.submitLauncher()
        try await assertNoConversation(fixture, original: original, launcher: true)
        #expect(!fixture.model.modelLibrary.ollamaAvailable)
    }

    @Test(arguments: [true, false])
    func duplicateSendAndTypingDuringPreflightKeepOneMessageAndNewDraft(launcher: Bool) async throws {
        let catalog = PreflightCatalog()
        let fixture = try makeFixture(catalog: catalog)
        defer { fixture.model.resetSession() }
        #expect(fixture.model.modelReference(launcher: true) == "custom:fixture")
        if !launcher {
            fixture.model.draft = AskDraft(text: "First", includeScreenshot: false)
            fixture.model.submitDraft()
            try await fixture.wait { fixture.model.busyIds.isEmpty }
        }
        let previous = fixture.model.selected
        let calls = await catalog.calls
        await catalog.configure(held: true)
        let original = AskDraft(text: "Original", includeScreenshot: false)
        if launcher { fixture.model.launcherDraft = original; fixture.model.submitLauncher() }
        else { fixture.model.draft = original; fixture.model.submitDraft() }
        #expect(!(launcher ? fixture.model.canSendLauncher : fixture.model.canSend))
        #expect(!fixture.model.canQueue)
        if launcher { fixture.model.submitLauncher() } else { fixture.model.submitDraft() }
        for _ in 0..<100 {
            if await catalog.calls > calls { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        if launcher { fixture.model.launcherDraft.text = "Next question" }
        else { fixture.model.draft.text = "Next question" }
        #expect(fixture.model.selected == previous)
        #expect(fixture.model.queuedMessages.isEmpty)
        await catalog.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.map(\.text) == (launcher ? ["Original"] : ["First", "Original"]))
        #expect((launcher ? fixture.model.launcherDraft : fixture.model.draft).text == "Next question")
        #expect(fixture.model.selected?.run?.status == "completed")
        #expect(fixture.model.selected?.modelRef == "custom:fixture")
        #expect(!fixture.model.hasPendingSubmission)
    }

    @Test(arguments: [true, false])
    func changingSelectionOrResettingSessionDropsLatePreflight(reset: Bool) async throws {
        let catalog = PreflightCatalog()
        await catalog.configure(held: true)
        let fixture = try makeFixture(catalog: catalog)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft = AskDraft(text: "Original", includeScreenshot: false)
        fixture.model.submitLauncher()
        for _ in 0..<100 {
            if await catalog.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        if reset { fixture.model.resetSession() } else { fixture.model.newConversation() }
        await catalog.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.submissionPreflights.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.conversations.isEmpty)
    }

    @Test func rejectedFollowUpAndQueuedSendKeepExistingHistory() async throws {
        let fixture = try makeFixture(local: false)
        defer { fixture.model.resetSession() }
        fixture.model.draft.text = "First"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        let value = try #require(fixture.model.selected)
        let cachedBefore = try await fixture.cache.load(id: value.id, owner: "owner")
        fixture.model.draft = AskDraft(text: "Follow-up", includeScreenshot: false, modelRef: "custom:missing")
        fixture.model.submitDraft()
        #expect(fixture.model.selected == value)
        #expect(fixture.model.draft.text == "Follow-up")
        let cachedAfter = try await fixture.cache.load(id: value.id, owner: "owner")
        // JSONValue decodes object keys in arbitrary order; compare canonical snapshots.
        let encoder = AskCoding.encoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(try #require(cachedBefore))
        let after = try encoder.encode(try #require(cachedAfter))
        #expect(after == before)
        let call = AskToolCall(id: "approval", function: .init(name: "browser", arguments: #"{"action":"read"}"#))
        await fixture.api.setTool(call)
        fixture.model.setPermissionMode(.strict, launcher: false)
        fixture.model.draft = AskDraft(text: "Busy turn", includeScreenshot: false)
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        fixture.model.draft = AskDraft(text: "Queued", includeScreenshot: false, modelRef: "custom:missing")
        fixture.model.submitDraft()
        #expect(fixture.model.queuedMessages.count == 1)
        fixture.model.approve(conversationId: value.id, allowed: true)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(fixture.model.queuedMessages.count == 1 && fixture.model.isQueuePaused)
        #expect(await fixture.api.sends.count == 2)
    }

    @Test func statusReflectsActualModelAvailability() throws {
        let fixture = try makeFixture()
        defer { fixture.model.resetSession() }
        let status = AskLocalModeStatus.make(model: fixture.model, signedIn: false)
        #expect(status.source == "Typeflux Cloud")
        #expect(!status.modelAvailable && status.modelReason != nil && status.offersSignIn)
        let cloud = try makeFixture(local: false)
        #expect(AskLocalModeStatus.make(model: cloud.model, signedIn: true).modelAvailable)
        cloud.model.draft.storesLocally = true
        #expect(!AskLocalModeStatus.make(model: cloud.model, signedIn: true).modelAvailable)
        #expect(!AskLocalModeStatus.make(model: cloud.model, signedIn: true).offersSignIn)
    }

    @Test func accountSwitchDuringValidationCannotSendTheOldDraftToTheNewAccount() async throws {
        let catalog = PreflightCatalog()
        await catalog.configure(held: true)
        let fixture = try makeFixture(catalog: catalog, local: false)
        defer { fixture.model.resetSession() }
        fixture.model.launcherDraft = AskDraft(text: "Private question", includeScreenshot: false, modelRef: "custom:fixture")
        fixture.model.submitLauncher()
        for _ in 0..<100 {
            if await catalog.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        fixture.sessionState.owner = "different-account"
        await catalog.release()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.submissionPreflights.isEmpty }
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.conversations.isEmpty)
    }

    @Test func missingSessionPreservesInputAndOffersSignIn() async throws {
        let fixture = try AskTestFixture(authenticated: false)
        defer { fixture.model.resetSession() }
        let original = AskDraft(text: "Keep me", includeScreenshot: false)
        fixture.model.launcherDraft = original
        fixture.model.submitLauncher()
        try await assertNoConversation(fixture, original: original, launcher: true)
        #expect(fixture.model.submissionIssues[true]?.offersSignIn == true)
    }

    @Test(arguments: ["endpoint", "chat", "scenario", "vision"])
    func unusableOwnModelsPreserveTheWholeDraft(reason: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.model.resetSession() }
        var entry = RegisteredModel(id: "fixture", name: "Fixture", reference: "custom:own", vision: false)
        if reason == "chat" { entry.chat = false }
        if reason == "scenario" { entry.scenarios = ["rewrite"] }
        var registry = fixture.model.modelLibrary.registry
        registry.providers.append(.init(id: "endpoint:own", name: "Own API", baseURL: reason == "endpoint" ? "" : "https://example.invalid/v1",
                                        models: [entry]))
        try fixture.model.modelLibrary.commit(registry)
        var original = AskDraft(text: "Keep me", includeScreenshot: false, modelRef: entry.reference)
        if reason == "vision" {
            original.attachments = [.init(kind: .image, name: "Image", image: "data:image/png;base64,YQ==")]
        }
        fixture.model.draft = original
        fixture.model.submitDraft()
        try await assertNoConversation(fixture, original: original, launcher: false)
        #expect(fixture.model.submissionIssues[false]?.offersModels == true)
    }
}
