import AppKit
import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureHandoffTests {
    init() {
        let previous = KeychainTokenStore.useInMemoryStoreForTesting
        KeychainTokenStore.useInMemoryStoreForTesting = true
        _ = AuthState.shared
        KeychainTokenStore.useInMemoryStoreForTesting = previous
    }

    @Test func settingsShortcutGoesDirectlyToItsWindowProcess() {
        #expect(FeatureHotkeyEvent.destination(for: .action(.openStudio)) == .settings)
    }

    @Test(arguments: ["", "chat", "activeChat", "otherPlugin", "fy Translate this"])
    func openingWithoutDraftTransferDismissesSourceAfterChatAccepts(input: String) async throws {
        let source = try AskTestFixture(), destination = try AskTestFixture()
        defer { source.model.resetSession(); destination.model.resetSession() }
        source.model.launcherDraft.text = input
        if input == "activeChat" || input == "otherPlugin" {
            source.model.plugins.enter(input == "activeChat" ? AskOpenChatPlugin.keywords[0] : AskTranslatePlugin.keywords[0])
            source.model.launcherDraft.text = input == "activeChat" ? "" : "Keep plugin input"
        }
        let draft = source.model.launcherDraft, keyword = source.model.plugins.keyword
        var dismissed = false, opened = false
        source.model.onDismissLauncher = { dismissed = true }
        destination.model.onShowConversation = { opened = true }
        source.model.featureRoute = { command in
            #expect(command.destination == .chat && command.action == "showChat")
            #expect(!dismissed && source.model.isOpeningChat)
            destination.model.onShowConversation?()
            return Data()
        }
        #expect(await source.model.openFeatureChat())
        #expect(opened && dismissed && !source.model.isOpeningChat)
        if input == "otherPlugin" || input.hasPrefix("fy ") {
            #expect(source.model.launcherDraft == draft)
            #expect(source.model.plugins.keyword == keyword)
        } else {
            #expect(source.model.launcherDraft.text.isEmpty)
            #expect(!source.model.plugins.isActive)
        }
        #expect(await destination.api.sends.isEmpty)
    }

    @Test(arguments: ["failure", "edit", "keyword", "account", "cancel"])
    func lateOrFailedEmptyOpenKeepsSourceVisible(change: String) async throws {
        let source = try AskTestFixture()
        defer { source.model.resetSession() }
        source.model.launcherDraft.text = "chat"
        var dismissed = false
        source.model.onDismissLauncher = { dismissed = true }
        source.model.featureRoute = { _ in
            switch change {
            case "failure": throw FeatureRPC.Failure.timedOut
            case "edit": source.model.launcherDraft.text = "New input"
            case "keyword": source.model.plugins.enter(AskTranslatePlugin.keywords[0])
            case "account": source.sessionState.owner = "another"
            default: withUnsafeCurrentTask { $0?.cancel() }
            }
            return Data()
        }
        let result = await Task { await source.model.openFeatureChat() }.value
        #expect(result == (change == "edit" || change == "keyword"))
        #expect(!dismissed && !source.model.isOpeningChat)
        #expect(source.model.launcherDraft.text == (change == "edit" ? "New input" : "chat"))
    }

    @Test func emptyOpenWaitsForRecordingAndDoesNotRouteTwice() async throws {
        let source = try AskTestFixture()
        defer { source.model.resetSession() }
        source.model.recordingIsActive = { true }
        source.model.featureRoute = { _ in
            Issue.record("A blocked open must not route")
            return Data()
        }
        #expect(await !source.model.openFeatureChat())
        source.model.recordingIsActive = { false }
        source.model.featureRoute = { _ in
            #expect(await !source.model.openFeatureChat())
            return Data()
        }
        #expect(await source.model.openFeatureChat())
    }

    @Test func remoteChatOpenDismissesTheActualLauncherWindow() async throws {
        _ = NSApplication.shared
        let source = try AskTestFixture()
        let controller = AskConversationWindowController(settings: source.model.modelLibrary.settings, model: source.model)
        defer { controller.dismissLauncher(); source.model.resetSession() }
        var prepared = false
        controller.showLauncher { prepared = true }
        try await source.wait { prepared }
        source.model.plugins.enter(AskOpenChatPlugin.keywords[0])
        source.model.launcherDraft.text = ""
        source.model.featureRoute = { _ in
            #expect(controller.launcherWindow?.isVisible == true)
            return Data()
        }
        #expect(await source.model.openFeatureChat())
        #expect(controller.launcherWindow?.isVisible == false)
    }

    @Test func fullDraftMovesOnlyAfterDestinationAcceptsIt() async throws {
        let source = try AskTestFixture(), destination = try AskTestFixture(cacheOverride: source.cache)
        defer { source.model.resetSession(); destination.model.resetSession() }
        let draft = AskDraft(text: "Review", includeScreenshot: false, selection: "Selected text", source: "Editor",
            sourceBundleID: "fixture.editor", modelRef: "cloud:default",
            references: [.init(messageId: "reference", text: "Quoted text")],
            attachments: [.init(kind: .file, name: "example.txt", text: "File contents")], skills: ["review"])
        source.model.launcherDraft = draft
        source.model.featureRoute = { command in
            #expect(source.model.launcherDraft == draft)
            let handoff = try JSONDecoder().decode(FeatureChatHandoff.self, from: command.payload)
            return try JSONEncoder().encode(await destination.model.receiveFeatureHandoff(handoff))
        }
        #expect(await source.model.transferFeatureDraft(draft, submit: false))
        #expect(destination.model.draft == draft)
        #expect(source.model.launcherDraft.text.isEmpty)
        #expect(destination.model.activeChatDraftID != nil)
        #expect(await destination.api.sends.isEmpty)
    }

    @Test func missingAcknowledgementPreservesSourceAndRetryDoesNotDuplicateDestination() async throws {
        let source = try AskTestFixture(), destination = try AskTestFixture(cacheOverride: source.cache)
        defer { source.model.resetSession(); destination.model.resetSession() }
        source.model.launcherDraft.text = "Never lose this"
        let draft = source.model.launcherDraft
        var attempts = 0
        source.model.featureRoute = { command in
            attempts += 1
            let handoff = try JSONDecoder().decode(FeatureChatHandoff.self, from: command.payload)
            let accepted = await destination.model.receiveFeatureHandoff(handoff)
            if attempts == 1 { throw FeatureRPC.Failure.timedOut }
            return try JSONEncoder().encode(accepted)
        }
        #expect(await !source.model.transferFeatureDraft(draft, submit: false))
        #expect(source.model.launcherDraft == draft)
        let acceptedID = destination.model.activeChatDraftID
        #expect(await source.model.transferFeatureDraft(draft, submit: false))
        #expect(destination.model.activeChatDraftID == acceptedID)
        #expect(destination.model.acceptedFeatureHandoffs.count == 1)
        #expect(attempts == 2)
        #expect(await destination.api.sends.isEmpty)
    }

    @Test func rejectedSubmitPreservesSourceAndExplicitRetrySendsOnlyOnce() async throws {
        let source = try AskTestFixture(), destination = try AskTestFixture(cacheOverride: source.cache)
        defer { source.model.resetSession(); destination.model.resetSession() }
        let draft = AskDraft(text: "Send after admission", includeScreenshot: false, modelRef: "cloud:default", storesLocally: false)
        source.model.launcherDraft = draft
        destination.model.onShowConversation = { destination.model.recordingIsActive = { true } }
        source.model.featureRoute = { command in
            let handoff = try JSONDecoder().decode(FeatureChatHandoff.self, from: command.payload)
            return try JSONEncoder().encode(await destination.model.receiveFeatureHandoff(handoff))
        }
        #expect(await !source.model.transferFeatureDraft(draft, submit: true))
        #expect(source.model.launcherDraft == draft)
        #expect(destination.model.draft == draft)
        #expect(destination.model.acceptedFeatureHandoffs.isEmpty)
        #expect(await destination.api.sends.isEmpty)
        destination.model.onShowConversation = nil
        destination.model.recordingIsActive = { false }
        #expect(await source.model.transferFeatureDraft(draft, submit: true))
        for _ in 0..<200 {
            if await !destination.api.sends.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await destination.api.sends.count == 1)
        #expect(destination.model.acceptedFeatureHandoffs.count == 1)
        #expect(source.model.launcherDraft.text.isEmpty)
    }

    @Test func sourceEditsAndAccountChangesSurviveLateAcknowledgements() async throws {
        for change in ["edit", "account"] {
            let source = try AskTestFixture()
            defer { source.model.resetSession() }
            source.model.launcherDraft.text = "Original"
            let draft = source.model.launcherDraft
            source.model.featureRoute = { _ in
                if change == "edit" { source.model.launcherDraft.text = "Newer text" }
                else { source.sessionState.owner = "another"; source.model.resetSession() }
                return try JSONEncoder().encode(true)
            }
            let accepted = await source.model.transferFeatureDraft(draft, submit: false)
            if change == "edit" {
                #expect(accepted)
                #expect(source.model.launcherDraft.text == "Newer text")
            } else { #expect(!accepted) }
        }
    }

    @Test func temporaryHandoffStaysOutOfPersistentDraftsAndRejectsWrongGeneration() async throws {
        let source = try AskTestFixture(), destination = try AskTestFixture(cacheOverride: source.cache)
        defer { source.model.resetSession(); destination.model.resetSession() }
        source.model.launcherDraft.text = "Private"
        source.model.launcherDraft.temporary = true
        let draft = source.model.launcherDraft
        source.model.featureRoute = { command in
            let handoff = try JSONDecoder().decode(FeatureChatHandoff.self, from: command.payload)
            return try JSONEncoder().encode(await destination.model.receiveFeatureHandoff(handoff))
        }
        #expect(await source.model.transferFeatureDraft(draft, submit: false))
        #expect(destination.model.draft.temporary == true)
        #expect(try await source.cache.savedChatDrafts(owner: "owner").isEmpty)
        let invalid = FeatureChatHandoff(id: "stale", owner: "owner", generation: AuthState.shared.sessionGeneration - 1,
            draft: draft, permission: "standard", reasoning: "providerDefault", submit: true)
        #expect(await !destination.model.receiveFeatureHandoff(invalid))
        #expect(await destination.api.sends.isEmpty)
    }
}
