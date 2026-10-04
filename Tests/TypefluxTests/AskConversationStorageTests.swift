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
        let fixture = try AskTestFixture(modelLibrary: library)
        fixture.model.commandSources = AskCommandSources(privateByDefault: { privateByDefault })
        return (fixture, profile.reference)
    }

    private func summary(_ id: String, _ offset: TimeInterval) -> AskConversation {
        AskConversation(id: id, title: id.uppercased(), revision: 1,
                        updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset), messages: [])
    }

    @Test func aPrivateConversationGoesToThisMacOnly() async throws {
        let (fixture, own) = try fixture()
        fixture.model.newConversation(storesLocally: true)
        #expect(fixture.model.storesLocally(launcher: false))
        #expect(!fixture.model.cloudAvailable)
        fixture.model.draft.text = "Keep this here"
        fixture.model.draft.modelRef = own
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        let id = try #require(fixture.model.selectedId)
        #expect(await fixture.localAPI.sends.count == 1)
        #expect(await fixture.api.sends.isEmpty)
        #expect(fixture.model.isLocal(id))
        #expect(fixture.model.localConversationIds == [id])
        // Its copy lives in the local partition, never under the account.
        #expect(try await fixture.cache.load(id: id, owner: AskRoutedAPI.localOwner) != nil)
        #expect(try await fixture.cache.load(id: id, owner: fixture.sessionState.owner) == nil)
        // Started conversations keep their place.
        #expect(!fixture.model.canChangeStorage(launcher: false))
        fixture.model.setStoresLocally(false, launcher: false)
        #expect(fixture.model.storesLocally(launcher: false))
    }

    @Test func aPrivateConversationsToolsRunUnderTheAccount() async throws {
        let (fixture, own) = try fixture()
        // Project and artifact scopes are read back with the account, so tools bind to it too.
        await fixture.localAPI.setTool(.init(id: "call", function: .init(name: "browser", arguments: #"{"action":"read"}"#)))
        fixture.model.newConversation(storesLocally: true)
        fixture.model.draft.text = "Read this page"
        fixture.model.draft.modelRef = own
        fixture.model.submitDraft()
        try await fixture.wait { !fixture.model.pendingApprovals.isEmpty }
        let id = try #require(fixture.model.selectedId)
        #expect(fixture.model.isLocal(id))
        #expect(fixture.tools.executionScope?.ownerId == fixture.sessionState.owner)
        #expect(fixture.tools.executionScope?.conversationId == id)
        fixture.model.approve(conversationId: id, allowed: false)
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.results.isEmpty)
    }

    @Test func aCloudConversationNeverTouchesTheLocalEngine() async throws {
        let (fixture, _) = try fixture()
        fixture.model.newConversation()
        #expect(!fixture.model.storesLocally(launcher: false))
        #expect(fixture.model.cloudAvailable)
        fixture.model.draft.text = "Sync this"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected?.run?.status == "completed" }
        let id = try #require(fixture.model.selectedId)
        #expect(await fixture.api.sends.count == 1)
        #expect(await fixture.localAPI.sends.isEmpty)
        #expect(!fixture.model.isLocal(id))
        #expect(try await fixture.cache.load(id: id, owner: fixture.sessionState.owner) != nil)
    }

    @Test func theDefaultAndTheDraftChoiceDecideNewConversations() throws {
        let (fixture, own) = try fixture(privateByDefault: true)
        #expect(fixture.model.storesLocally(launcher: true))
        #expect(fixture.model.storesLocally(launcher: false))
        fixture.model.setStoresLocally(false, launcher: true)
        #expect(!fixture.model.storesLocally(launcher: true))
        #expect(fixture.model.storesLocally(launcher: false))
        // A Cloud reference in a private draft falls back to the user's own model.
        #expect(fixture.model.modelReference(launcher: false) == own)
        fixture.model.newConversation(storesLocally: false)
        #expect(!fixture.model.storesLocally(launcher: false))
        #expect(fixture.model.localFallback("cloud:default", hasImage: false, local: false) == "cloud:default")
        #expect(fixture.model.localFallback("cloud:default", hasImage: false, local: true) == own)
    }

    @Test func historyListsBothKindsWithoutMovingRows() async throws {
        let (fixture, _) = try fixture()
        await fixture.api.seed(summary("a", 30))
        await fixture.api.seed(summary("b", 10))
        await fixture.localAPI.seed(summary("p", 20))
        await fixture.model.refreshHistory()
        #expect(fixture.model.conversations.map(\.id) == ["a", "p", "b"])
        #expect(fixture.model.localConversationIds == ["p"])
        #expect(fixture.model.isLocal("p") && !fixture.model.isLocal("a"))

        // A local list that fails to load keeps the private rows it already had.
        await fixture.localAPI.setFailList(true)
        await fixture.model.refreshHistory()
        #expect(fixture.model.conversations.map(\.id) == ["a", "p", "b"])
        await fixture.localAPI.setFailList(false)

        // Deleted elsewhere: the next read drops it.
        try await fixture.localAPI.delete(conversationId: "p", token: "")
        await fixture.model.refreshHistory()
        #expect(fixture.model.conversations.map(\.id) == ["a", "b"])
    }

    @Test func everyLocalPageIsListed() async throws {
        let (fixture, _) = try fixture()
        for index in 0 ..< 55 { await fixture.localAPI.seed(summary("p\(index)", TimeInterval(index))) }
        await fixture.model.refreshHistory()
        #expect(fixture.model.localConversationIds.count == 55)
        #expect(fixture.model.conversations.count == 55)
    }

    @Test func theWorkspaceMarksPrivateConversations() async throws {
        let (fixture, _) = try fixture()
        await fixture.api.seed(summary("a", 30))
        await fixture.localAPI.seed(summary("p", 20))
        await fixture.model.refreshHistory()
        await fixture.model.select("p")
        let auth = AuthState(loadStoredToken: { nil }, loadStoredRefreshToken: { nil }, loadStoredUserProfile: { nil })
        let host = try AskStorageViewportTestHost(model: fixture.model, auth: auth)
        defer { host.close() }
        for newConversation in [false, true] {
            if newConversation { fixture.model.newConversation(storesLocally: true) }
            fixture.model.draft.text = "Keep this draft private"
            for size in [NSSize(width: 1000, height: 760), NSSize(width: 440, height: 320)] {
                try await host.resize(to: size)
                try host.assertComposer(text: "Keep this draft private")
                try host.assertVisible(label: L("ask.storage.local"))
                #expect(fixture.model.storesLocally(launcher: false))
                #expect(fixture.model.selectedId == (newConversation ? nil : "p"))
            }
        }
    }

    @Test func filterBarPicksAFilter() {
        var selection = AskHistoryFilter.all
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let hosting = NSHostingView(rootView: AskHistoryFilterBar(selection: binding).frame(width: 240))
        hosting.layoutSubtreeIfNeeded()
        #expect(abs(hosting.fittingSize.height - AskHistoryFilterBar.height) < 1)
        #expect(AskHistoryFilter.all.symbol == nil)
        #expect(AskHistoryFilter.cloud.symbol == "cloud")
        #expect(AskHistoryFilter.local.symbol == "lock")
    }

    @Test func settingsStoreTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ask-storage-settings-" + UUID().uuidString))
        let settings = SettingsStore(defaults: defaults)
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
        let (fixture, _) = try fixture()
        try await fixture.cache.save(summary("p", 20), owner: AskRoutedAPI.localOwner)
        try await fixture.cache.save(summary("a", 30), owner: fixture.sessionState.owner)
        await fixture.api.setFailList(true)
        await fixture.model.refreshHistory()
        #expect(fixture.model.conversations.map(\.id) == ["a", "p"])
        #expect(fixture.model.localConversationIds.contains("p"))
    }

    @Test func selectingAndDeletingAPrivateConversationUseTheLocalEngine() async throws {
        let (fixture, _) = try fixture()
        await fixture.localAPI.seed(summary("p", 20))
        await fixture.model.refreshHistory()
        await fixture.model.select("p")
        #expect(fixture.model.selected?.id == "p")
        #expect(fixture.model.storesLocally(launcher: false))
        #expect(!fixture.model.canChangeStorage(launcher: false))

        // Its follow-up draft is saved with it, in the local partition.
        fixture.model.draft.text = "later"
        fixture.model.persistDrafts()
        for _ in 0 ..< 400 {
            if try await fixture.cache.draft(key: "p", owner: AskRoutedAPI.localOwner) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await fixture.cache.draft(key: "p", owner: AskRoutedAPI.localOwner)?.text == "later")

        await fixture.model.delete("p")
        #expect(await fixture.localAPI.values["p"] == nil)
        #expect(fixture.model.conversations.isEmpty)
        #expect(fixture.model.localConversationIds.isEmpty)
        #expect(fixture.model.selectedId == nil)
    }

    @Test func signedOutEverythingStaysOnThisMac() throws {
        let fixture = try AskTestFixture(localOnly: true)
        #expect(!fixture.model.isSignedIn)
        #expect(fixture.model.storesLocally(launcher: false))
        #expect(fixture.model.storesLocally(launcher: true))
        #expect(fixture.model.isLocal("any"))
        #expect(!fixture.model.canChangeStorage(launcher: true))
        fixture.model.newConversation(storesLocally: false)
        #expect(fixture.model.draft.storesLocally == nil)
        #expect(fixture.model.storesLocally(launcher: false))
        let context = fixture.model.commandContext(launcher: false)
        #expect(context.localMode)
        #expect(context.storageLocked == L("ask.storage.signedOut"))
    }

    @Test func theLocalCommandIsLockedOnceAConversationStarted() async throws {
        let (fixture, _) = try fixture()
        await fixture.api.seed(summary("a", 30))
        await fixture.model.select("a")
        let context = fixture.model.commandContext(launcher: false)
        #expect(!context.localMode)
        #expect(context.storageLocked == L("ask.storage.locked"))
        let command = try #require(AskCommandCatalog.commands(context).first { $0.action == .localMode })
        #expect(command.disabledReason == L("ask.storage.locked"))
        fixture.model.runCommand(command, launcher: false)
        #expect(!fixture.model.storesLocally(launcher: false))
        // The launcher always starts a new conversation, so it can still choose.
        #expect(fixture.model.commandContext(launcher: true).storageLocked == nil)
        fixture.model.newConversation()
        let open = try #require(AskCommandCatalog.commands(fixture.model.commandContext(launcher: false))
            .first { $0.action == .localMode })
        #expect(open.enabled)
        fixture.model.runCommand(open, launcher: false)
        #expect(fixture.model.storesLocally(launcher: false))
        fixture.model.runCommand(open, launcher: false)
        #expect(!fixture.model.storesLocally(launcher: false))
        #expect(fixture.model.commandFeedback == L("ask.command.localOff"))
    }

    @Test func statusDescribesTheComposersConversation() throws {
        let (fixture, _) = try fixture()
        let cloud = AskLocalModeStatus.make(model: fixture.model, signedIn: true)
        #expect(!cloud.local && cloud.changeable && !cloud.offersSignIn)
        #expect(cloud.summaryKey == "ask.storage.card.choose")
        fixture.model.setStoresLocally(true, launcher: false)
        let local = AskLocalModeStatus.make(model: fixture.model, signedIn: true)
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

/// These storage surfaces must remain usable inside the actual viewport, including short windows.
@MainActor
final class AskStorageViewportTestHost {
    private let window: NSWindow
    private let suite = "ask-storage-viewport-" + UUID().uuidString
    private let defaults: UserDefaults
    private let accessibility = AskWorkspaceTestAccessibility()

    init(model: AskConversationModel, auth: AuthState) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "ask.sidebarCollapsed")
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1180, height: 760),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AskConversationView(model: model, auth: auth).defaultAppStorage(defaults))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
    }

    func resize(to size: NSSize) async throws {
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func assertComposer(text: String) throws {
        let content = try #require(window.contentView)
        func editor(in view: NSView) -> AskComposerTextView.Editor? {
            if let editor = view as? AskComposerTextView.Editor { return editor }
            for child in view.subviews {
                if let found = editor(in: child) { return found }
            }
            return nil
        }
        let editor = try #require(editor(in: content))
        let scroll = try #require(editor.enclosingScrollView)
        let frame = scroll.convert(scroll.bounds, to: content)
        #expect(frame.width > 100 && frame.height >= 28)
        #expect(content.bounds.insetBy(dx: -1, dy: -1).contains(frame))
        #expect(editor.string == text)
        for identifier in ["ask.composer.attach", "ask.composer.model", "ask.composer.voice", "ask.composer.send"] {
            let frames = accessibleFrames(key: "accessibilityIdentifier", value: identifier)
            #expect(frames.contains(where: isVisible), "Composer control outside viewport: \(identifier)")
        }
    }

    func assertVisible(label: String) throws {
        #expect(accessibleFrames(key: "accessibilityLabel", value: label).contains(where: isVisible),
                "Missing visible storage state: \(label)")
    }

    private func isVisible(_ frame: NSRect) -> Bool {
        guard frame.width > 0, frame.height > 0, let content = window.contentView else { return false }
        let local = content.convert(window.convertFromScreen(frame), from: nil)
        return content.bounds.insetBy(dx: -1, dy: -1).contains(local)
    }

    private func accessibleFrames(key: String, value expected: String) -> [NSRect] {
        var seen = Set<ObjectIdentifier>()
        var frames: [NSRect] = []
        func value(_ object: NSObject, _ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if value(object, key) as? String == expected,
               let frame = value(object, "accessibilityFrame") as? NSValue {
                frames.append(frame.rectValue)
            }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] { visit(child) }
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        return frames
    }

    func close() {
        window.orderOut(nil)
        window.close()
        defaults.removePersistentDomain(forName: suite)
        accessibility.restore()
    }
}
