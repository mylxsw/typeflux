import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Typeflux

/// Each conversation is kept either in Typeflux Cloud or on this Mac. Signed in, both
/// kinds share one history; the place is chosen before the first message and then fixed.
@Suite("Ask conversation storage", .serialized)
@MainActor
struct AskConversationStorageTests {
    /// A signed-in fixture with one of the user's own models, so a private conversation can send.
    private func fixture(privateByDefault: Bool = false) throws -> (AskTestFixture, String) {
        let suite = "ask-storage-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = AskModelProfile(name: "My model", baseURL: "https://models.example/v1", model: "my-model")
        defaults.set(try JSONEncoder().encode([profile]), forKey: "llm.model.profiles")
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let f = try AskTestFixture(modelLibrary: library)
        f.model.commandSources = AskCommandSources(privateByDefault: { privateByDefault })
        return (f, profile.reference)
    }

    private func summary(_ id: String, _ offset: TimeInterval) -> AskConversation {
        AskConversation(id: id, title: id.uppercased(), revision: 1,
                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), messages: [])
    }

    @Test func aPrivateConversationGoesToThisMacOnly() async throws {
        let (f, own) = try fixture()
        f.model.newConversation(storesLocally: true)
        #expect(f.model.storesLocally(launcher: false))
        #expect(!f.model.cloudAvailable)
        f.model.draft.text = "Keep this here"
        f.model.draft.modelRef = own
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        let id = try #require(f.model.selectedId)
        #expect(await f.localAPI.sends.count == 1)
        #expect(await f.api.sends.isEmpty)
        #expect(f.model.isLocal(id))
        #expect(f.model.localConversationIds == [id])
        // Its copy lives in the local partition, never under the account.
        #expect(try await f.cache.load(id: id, owner: AskRoutedAPI.localOwner) != nil)
        #expect(try await f.cache.load(id: id, owner: f.sessionState.owner) == nil)
        // Started conversations keep their place.
        #expect(!f.model.canChangeStorage(launcher: false))
        f.model.setStoresLocally(false, launcher: false)
        #expect(f.model.storesLocally(launcher: false))
    }

    @Test func aCloudConversationNeverTouchesTheLocalEngine() async throws {
        let (f, _) = try fixture()
        f.model.newConversation()
        #expect(!f.model.storesLocally(launcher: false))
        #expect(f.model.cloudAvailable)
        f.model.draft.text = "Sync this"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.run?.status == "completed" }
        let id = try #require(f.model.selectedId)
        #expect(await f.api.sends.count == 1)
        #expect(await f.localAPI.sends.isEmpty)
        #expect(!f.model.isLocal(id))
        #expect(try await f.cache.load(id: id, owner: f.sessionState.owner) != nil)
    }

    @Test func theDefaultAndTheDraftChoiceDecideNewConversations() throws {
        let (f, own) = try fixture(privateByDefault: true)
        #expect(f.model.storesLocally(launcher: true))
        #expect(f.model.storesLocally(launcher: false))
        f.model.setStoresLocally(false, launcher: true)
        #expect(!f.model.storesLocally(launcher: true))
        #expect(f.model.storesLocally(launcher: false))
        // A Cloud reference in a private draft falls back to the user's own model.
        #expect(f.model.modelReference(launcher: false) == own)
        f.model.newConversation(storesLocally: false)
        #expect(!f.model.storesLocally(launcher: false))
        #expect(f.model.localFallback("cloud:default", hasImage: false, local: false) == "cloud:default")
        #expect(f.model.localFallback("cloud:default", hasImage: false, local: true) == own)
    }

    @Test func historyListsBothKindsWithoutMovingRows() async throws {
        let (f, _) = try fixture()
        await f.api.seed(summary("a", 30))
        await f.api.seed(summary("b", 10))
        await f.localAPI.seed(summary("p", 20))
        await f.model.refreshHistory()
        #expect(f.model.conversations.map(\.id) == ["a", "p", "b"])
        #expect(f.model.localConversationIds == ["p"])
        #expect(f.model.isLocal("p") && !f.model.isLocal("a"))

        // A local list that fails to load keeps the private rows it already had.
        await f.localAPI.setFailList(true)
        await f.model.refreshHistory()
        #expect(f.model.conversations.map(\.id) == ["a", "p", "b"])
        await f.localAPI.setFailList(false)

        // Deleted elsewhere: the next read drops it.
        try await f.localAPI.delete(conversationId: "p", token: "")
        await f.model.refreshHistory()
        #expect(f.model.conversations.map(\.id) == ["a", "b"])
    }

    @Test func everyLocalPageIsListed() async throws {
        let (f, _) = try fixture()
        for index in 0 ..< 55 { await f.localAPI.seed(summary("p\(index)", TimeInterval(index))) }
        await f.model.refreshHistory()
        #expect(f.model.localConversationIds.count == 55)
        #expect(f.model.conversations.count == 55)
    }

    @Test func theWorkspaceMarksPrivateConversations() async throws {
        let (f, _) = try fixture()
        await f.api.seed(summary("a", 30))
        await f.localAPI.seed(summary("p", 20))
        await f.model.refreshHistory()
        await f.model.select("p")
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil })
        let hosting = NSHostingView(rootView: AskConversationView(model: f.model, auth: auth).frame(width: 1000))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height >= 530)
        f.model.newConversation(storesLocally: true)
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height >= 530)
    }

    @Test func settingsStoreTheDefault() throws {
        let settings = SettingsStore(defaults: try #require(UserDefaults(suiteName: "ask-storage-settings-" + UUID().uuidString)))
        #expect(!settings.askNewConversationsStayLocal)
        // The key predates per-conversation storage; local mode carries over.
        settings.defaults.set(true, forKey: "ask.localMode")
        #expect(settings.askNewConversationsStayLocal)
        let view = AskToolsSettingsView(settings: settings)
        view.setNewConversationsStayLocal(false)
        #expect(!settings.askNewConversationsStayLocal)
        view.setNewConversationsStayLocal(true)
        #expect(settings.askNewConversationsStayLocal)
        #expect(AskToolsSettingsView.storageName(local: true) == L("ask.storage.local"))
        #expect(AskToolsSettingsView.storageName(local: false) == L("ask.storage.cloud"))
    }

    @Test func cachedHistoryShowsPrivateRowsBeforeTheNetworkAnswers() async throws {
        let (f, _) = try fixture()
        try await f.cache.save(summary("p", 20), owner: AskRoutedAPI.localOwner)
        try await f.cache.save(summary("a", 30), owner: f.sessionState.owner)
        await f.api.setFailList(true)
        await f.model.refreshHistory()
        #expect(f.model.conversations.map(\.id) == ["a", "p"])
        #expect(f.model.localConversationIds.contains("p"))
    }

    @Test func selectingAndDeletingAPrivateConversationUseTheLocalEngine() async throws {
        let (f, _) = try fixture()
        await f.localAPI.seed(summary("p", 20))
        await f.model.refreshHistory()
        await f.model.select("p")
        #expect(f.model.selected?.id == "p")
        #expect(f.model.storesLocally(launcher: false))
        #expect(!f.model.canChangeStorage(launcher: false))

        // Its follow-up draft is saved with it, in the local partition.
        f.model.draft.text = "later"
        f.model.persistDrafts()
        for _ in 0 ..< 400 {
            if try await f.cache.draft(key: "p", owner: AskRoutedAPI.localOwner) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await f.cache.draft(key: "p", owner: AskRoutedAPI.localOwner)?.text == "later")

        await f.model.delete("p")
        #expect(await f.localAPI.values["p"] == nil)
        #expect(f.model.conversations.isEmpty)
        #expect(f.model.localConversationIds.isEmpty)
        #expect(f.model.selectedId == nil)
    }

    @Test func signedOutEverythingStaysOnThisMac() throws {
        let f = try AskTestFixture(localOnly: true)
        #expect(!f.model.isSignedIn)
        #expect(f.model.storesLocally(launcher: false))
        #expect(f.model.storesLocally(launcher: true))
        #expect(f.model.isLocal("any"))
        #expect(!f.model.canChangeStorage(launcher: true))
        f.model.newConversation(storesLocally: false)
        #expect(f.model.draft.storesLocally == nil)
        #expect(f.model.storesLocally(launcher: false))
        let context = f.model.commandContext(launcher: false)
        #expect(context.localMode)
        #expect(context.storageLocked == L("ask.storage.signedOut"))
    }

    @Test func theLocalCommandIsLockedOnceAConversationStarted() async throws {
        let (f, _) = try fixture()
        await f.api.seed(summary("a", 30))
        await f.model.select("a")
        let context = f.model.commandContext(launcher: false)
        #expect(!context.localMode)
        #expect(context.storageLocked == L("ask.storage.locked"))
        let command = try #require(AskCommandCatalog.commands(context).first { $0.action == .localMode })
        #expect(command.disabledReason == L("ask.storage.locked"))
        f.model.runCommand(command, launcher: false)
        #expect(!f.model.storesLocally(launcher: false))
        // The launcher always starts a new conversation, so it can still choose.
        #expect(f.model.commandContext(launcher: true).storageLocked == nil)
    }

    @Test func statusDescribesTheComposersConversation() throws {
        let (f, _) = try fixture()
        let cloud = AskLocalModeStatus.make(model: f.model, signedIn: true)
        #expect(!cloud.local && cloud.changeable && !cloud.offersSignIn)
        #expect(cloud.summaryKey == "ask.storage.card.choose")
        f.model.setStoresLocally(true, launcher: false)
        let local = AskLocalModeStatus.make(model: f.model, signedIn: true)
        #expect(local.local && local.source == "My model")
        #expect(AskLocalModeStatus(source: "", searchConfigured: true, offersSignIn: false).summaryKey
            == "ask.storage.card.lockedLocal")
        #expect(AskLocalModeStatus(source: "", searchConfigured: true, offersSignIn: false, local: false).summaryKey
            == "ask.storage.card.lockedCloud")
        #expect(AskLocalModeStatus(source: "", searchConfigured: true, offersSignIn: true).summaryKey
            == "ask.local.card.body")
    }

    @Test func rowsAreInsertedByDateAndFiltered() {
        let date = { (offset: TimeInterval) in Date(timeIntervalSince1970: 1_800_000_000 + offset) }
        let list = [AskConversationSummary(id: "a", title: "A", updatedAt: date(30)),
                    AskConversationSummary(id: "b", title: "B", updatedAt: date(10))]
        let added = AskConversationModel.insertingByDate(
            [.init(id: "p", title: "P", updatedAt: date(20)), .init(id: "q", title: "Q", updatedAt: date(0)),
             .init(id: "a", title: "dup", updatedAt: date(99))], into: list)
        #expect(added.map(\.id) == ["a", "p", "b", "q"])
        #expect(added.first?.title == "A")
        let isLocal = { (id: String) in id == "p" || id == "q" }
        #expect(AskHistoryFilter.all.apply(added, isLocal: isLocal).map(\.id) == ["a", "p", "b", "q"])
        #expect(AskHistoryFilter.cloud.apply(added, isLocal: isLocal).map(\.id) == ["a", "b"])
        #expect(AskHistoryFilter.local.apply(added, isLocal: isLocal).map(\.id) == ["p", "q"])
        #expect(AskHistoryFilter.local.titleKey == "ask.history.filter.local")
    }

    @Test func storageCopyExistsInEveryLanguage() throws {
        let keys = ["ask.storage.local", "ask.storage.cloud", "ask.storage.local.detail", "ask.storage.cloud.detail",
                    "ask.storage.help", "ask.storage.card.choose", "ask.storage.card.lockedLocal",
                    "ask.storage.card.lockedCloud", "ask.storage.card.localNote", "ask.storage.card.cloudNote",
                    "ask.storage.newLocal", "ask.storage.newCloud", "ask.storage.locked", "ask.storage.signedOut",
                    "ask.history.filter", "ask.history.filter.all", "ask.history.filter.cloud",
                    "ask.history.filter.local"]
        for language in AppLanguage.allCases {
            let path = try #require(language.bundleLocalizationCandidates.compactMap {
                Bundle.module.path(forResource: $0, ofType: "lproj")
            }.first)
            let bundle = try #require(Bundle(path: path))
            for key in keys {
                #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(key) in \(language)")
            }
        }
    }
}
