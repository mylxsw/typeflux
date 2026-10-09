import Foundation
import Testing
@testable import Typeflux

@MainActor
private final class AskMemoryCapture: AskContextCapturing {
    var captured: AskMemory?
    var global: AskMemory?
    func capture(includeScreenshot: Bool, includeSelection: Bool, request: ReadOnlySelectionRequest) async -> AskCapturedContext {
        .init(selection: nil, source: "Xcode", memory: captured)
    }
    func globalMemory() -> AskMemory? { global }
}

@MainActor
private struct AskMemoryFixture {
    let api = AskTestAPI()
    let capture = AskMemoryCapture()
    let defaults: UserDefaults
    let model: AskConversationModel
    init(authenticated: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-memory-" + UUID().uuidString)
        let cache = try AskConversationCache(url: root.appendingPathComponent("cache.sqlite"))
        defaults = UserDefaults(suiteName: "ask-memory-" + UUID().uuidString)!
        let library = AskModelLibrary(defaults: UserDefaults(suiteName: "ask-memory-library-" + UUID().uuidString)!,
                                      automaticallyLoadsCatalog: false)
        model = AskConversationModel(api: api, cache: cache, tools: AskTestTools(), capture: capture,
                                     deviceId: "device", modelLibrary: library, defaults: defaults,
                                     session: { authenticated ? ("owner", "token") : nil })
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting for memory state")
    }
}

private struct SoulFile: Encodable {
    var souls: [String: GlobalSoulMemory]
    var pending: [GlobalSoulInput] = []
}

@MainActor
private struct ProviderFixture {
    let settings: SettingsStore
    let souls: GlobalSoulMemoryStore
    let recent: RecentInputMemoryStore

    init(soul: String? = "Backend engineer who prefers concise answers.") throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-memory-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let soulURL = root.appendingPathComponent("soul.json")
        if let soul {
            let file = SoulFile(souls: ["owner": GlobalSoulMemory(text: soul, updatedAt: Date())])
            try JSONEncoder().encode(file).write(to: soulURL)
        }
        settings = SettingsStore(defaults: UserDefaults(suiteName: "ask-memory-settings-" + UUID().uuidString)!)
        settings.recentInputMemoryEnabled = true
        settings.globalSoulMemoryEnabled = true
        souls = GlobalSoulMemoryStore(fileURL: soulURL)
        recent = RecentInputMemoryStore(fileURL: root.appendingPathComponent("recent.json"))
    }

    func provider(resolve: @escaping (String) -> RecentInputMemoryScope? = {
        RecentInputMemoryScope(appIdentifier: $0, key: $0)
    }) -> AskMemoryProvider {
        AskMemoryProvider(settings: settings, soulStore: souls, recentStore: recent,
                          ownerID: { "owner" }, ownBundleIdentifier: "ai.typeflux.app", resolveScope: resolve)
    }

    func remember(_ text: String, app: String = "com.apple.dt.Xcode", scope: String? = nil, at date: Date = Date()) {
        recent.upsert(id: UUID(), appIdentifier: app, scope: scope ?? app, text: text, at: date, owner: "owner")
    }
}

@Suite("Ask memory", .exclusiveUIState)
@MainActor
struct AskMemoryTests {
    // MARK: - Value

    @Test func emptinessClippingAndTitles() {
        #expect(AskMemory().isEmpty)
        #expect(AskMemory(global: "").isEmpty)
        #expect(AskMemory(app: .init(id: "a", excerpts: [])).isEmpty)
        #expect(!AskMemory(global: "soul").isEmpty)
        #expect(!AskMemory(app: .init(id: "a", excerpts: ["x"])).isEmpty)

        #expect(AskMemory.clipped("  short \n", to: 10) == "short")
        let clipped = AskMemory.clipped(String(repeating: "字", count: 12), to: 10)
        #expect(clipped.unicodeScalars.count == 10)
        // Clipping counts scalars, matching the server's rune limit, even inside a grapheme.
        #expect(AskMemory.clipped("👩‍💻👩‍💻", to: 2).unicodeScalars.count == 2)

        #expect(AskMemory(global: "soul").chipTitle == L("ask.memory"))
        #expect(AskMemory(global: "soul", app: .init(id: "a", name: "Xcode", excerpts: [])).chipTitle == L("ask.memory"))
        #expect(AskMemory(app: .init(id: "com.example", name: "Xcode", excerpts: ["x"])).chipTitle == L("ask.memory.app", "Xcode"))
        #expect(AskMemory(app: .init(id: "com.example", excerpts: ["x"])).chipTitle == L("ask.memory.app", "com.example"))
        #expect(L("ask.memory") != "ask.memory")
        #expect(L("ask.memory.help") != "ask.memory.help")
        #expect(L("ask.memory.pinned") != "ask.memory.pinned")
    }

    @Test func sendRequestEncodesMemoryInServerShape() throws {
        var request = AskSendRequest(id: "m", deviceId: "d", text: "Q", tools: [])
        request.memory = AskMemory(global: "soul", app: .init(id: "com.apple.Safari", name: "Safari", excerpts: ["draft"]))
        let data = try AskCoding.encoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let memory = try #require(object["memory"] as? [String: Any])
        #expect(memory["global"] as? String == "soul")
        let app = try #require(memory["app"] as? [String: Any])
        #expect(app["id"] as? String == "com.apple.Safari")
        #expect(app["name"] as? String == "Safari")
        #expect(app["excerpts"] as? [String] == ["draft"])
        #expect(try AskCoding.decoder().decode(AskSendRequest.self, from: data) == request)

        let plain = try AskCoding.encoder().encode(AskSendRequest(id: "m", deviceId: "d", text: "Q", tools: []))
        #expect(!String(decoding: plain, as: UTF8.self).contains("memory"))
    }

    @Test func legacyDraftsAndConversationsDecodeWithoutMemory() throws {
        let draft = try AskCoding.decoder().decode(AskDraft.self, from: Data(#"{"text":"q","include_screenshot":true}"#.utf8))
        #expect(draft.memory == nil)
        let conversation = try AskCoding.decoder().decode(AskConversation.self, from: Data(
            #"{"id":"c","title":"t","revision":1,"updated_at":"2026-01-01T00:00:00Z","messages":[],"memory":{"global":"soul"}}"#.utf8
        ))
        #expect(conversation.memory == AskMemory(global: "soul"))
    }

    // MARK: - Provider

    @Test func providerIncludesGlobalAndMatchingApplication() throws {
        let f = try ProviderFixture()
        f.remember("older", at: Date().addingTimeInterval(-60))
        f.remember("newer")
        f.remember("other app", app: "com.apple.Safari")
        let memory = try #require(f.provider().memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode"))
        #expect(memory.global == "Backend engineer who prefers concise answers.")
        #expect(memory.app == .init(id: "com.apple.dt.Xcode", name: "Xcode", excerpts: ["newer", "older"]))

        let global = try #require(f.provider().memory(bundleIdentifier: nil, appName: nil))
        #expect(global.app == nil)
        #expect(global.global != nil)
    }

    @Test func providerRespectsGlobalSwitchAndMissingSoul() throws {
        let f = try ProviderFixture()
        f.remember("draft")
        f.settings.globalSoulMemoryEnabled = false
        let memory = try #require(f.provider().memory(bundleIdentifier: "com.apple.dt.Xcode", appName: nil))
        #expect(memory.global == nil)
        #expect(memory.app?.name == nil)
        #expect(f.provider().memory(bundleIdentifier: nil, appName: nil) == nil)

        let empty = try ProviderFixture(soul: nil)
        #expect(empty.provider().memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode") == nil)
        let blank = try ProviderFixture(soul: "   ")
        #expect(blank.provider().memory(bundleIdentifier: nil, appName: nil) == nil)
    }

    @Test func providerSkipsDisallowedApplicationsBeforeResolvingScope() throws {
        let f = try ProviderFixture()
        f.remember("draft")
        var resolved: [String] = []
        let provider = f.provider { resolved.append($0); return RecentInputMemoryScope(appIdentifier: $0, key: $0) }

        f.settings.recentInputMemoryExcludedApps = ["com.apple.dt.Xcode"]
        #expect(provider.memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")?.app == nil)
        f.settings.recentInputMemoryExcludedApps = []
        f.settings.recentInputMemoryEnabled = false
        #expect(provider.memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")?.app == nil)
        f.settings.recentInputMemoryEnabled = true
        #expect(provider.memory(bundleIdentifier: "ai.typeflux.app", appName: "Typeflux")?.app == nil)
        #expect(provider.memory(bundleIdentifier: "", appName: nil)?.app == nil)
        #expect(provider.memory(bundleIdentifier: String(repeating: "a", count: 257), appName: nil)?.app == nil)
        #expect(resolved.isEmpty)

        #expect(provider.memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode")?.app != nil)
        #expect(resolved == ["com.apple.dt.Xcode"])
    }

    @Test func providerUsesResolvedBrowserPageScope() throws {
        let f = try ProviderFixture()
        f.remember("page one", app: "com.apple.Safari", scope: "com.apple.Safari|one")
        f.remember("page two", app: "com.apple.Safari", scope: "com.apple.Safari|two")
        let page = f.provider { RecentInputMemoryScope(appIdentifier: $0, key: "\($0)|two") }
        #expect(page.memory(bundleIdentifier: "com.apple.Safari", appName: "Safari")?.app?.excerpts == ["page two"])
        // An unresolvable page (for example, no URL) yields no application memory.
        let unresolved = f.provider { _ in nil }
        let memory = try #require(unresolved.memory(bundleIdentifier: "com.apple.Safari", appName: "Safari"))
        #expect(memory.app == nil)
    }

    @Test func providerLimitsAndClipsExcerpts() throws {
        let f = try ProviderFixture(soul: String(repeating: "g", count: 1200))
        for index in 0 ..< 6 { f.remember("excerpt \(index)", at: Date().addingTimeInterval(Double(index))) }
        let long = String(repeating: "n", count: 300)
        let memory = try #require(f.provider().memory(bundleIdentifier: "com.apple.dt.Xcode", appName: long))
        #expect(memory.global?.count == AskMemory.maximumGlobalLength)
        #expect(memory.app?.excerpts == ["excerpt 5", "excerpt 4", "excerpt 3", "excerpt 2"])
        #expect(memory.app?.name?.count == AskMemory.maximumAppNameLength)
        #expect(f.provider().memory(bundleIdentifier: "com.apple.dt.Xcode", appName: "  ")?.app?.name == nil)
    }

    // MARK: - Conversation model

    @Test func launcherSendsCapturedMemoryOnlyWithTheOpeningMessage() async throws {
        let f = try AskMemoryFixture()
        let captured = AskMemory(global: "soul", app: .init(id: "com.apple.dt.Xcode", name: "Xcode", excerpts: ["draft"]))
        f.capture.captured = captured
        f.capture.global = AskMemory(global: "fallback")
        await f.model.prepareLauncher()
        #expect(f.model.launcherDraft.memory == captured)
        f.model.launcherDraft.text = "Question"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 2 }
        #expect(f.model.selected?.memory == captured)
        #expect(f.model.launcherDraft.memory == nil)

        f.model.draft.text = "Follow up"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 4 }
        let sends = await f.api.sends
        #expect(sends.count == 2)
        #expect(sends[0].memory == captured)
        #expect(sends[1].memory == nil)
        #expect(f.model.selected?.memory == captured)
    }

    @Test func memorySwitchedOffIsNotSentAndCanBeSwitchedBackOn() async throws {
        let f = try AskMemoryFixture()
        let captured = AskMemory(global: "soul", app: .init(id: "com.apple.dt.Xcode", name: "Xcode", excerpts: ["draft"]))
        f.capture.captured = captured
        f.capture.global = AskMemory(global: "fallback")
        await f.model.prepareLauncher()
        f.model.launcherDraft.memoryOff = true
        // Switching off keeps the captured memory, so switching back on restores it.
        #expect(f.model.launcherDraft.memory == captured)
        f.model.launcherDraft.text = "Question"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected != nil }
        #expect(await f.api.sends.first?.memory == nil)

        let again = try AskMemoryFixture()
        again.capture.captured = captured
        await again.model.prepareLauncher()
        again.model.launcherDraft.memoryOff = true
        again.model.launcherDraft.memoryOff = nil
        again.model.launcherDraft.text = "Question"
        again.model.submitLauncher()
        try await again.wait { again.model.busyIds.isEmpty && again.model.selected != nil }
        #expect(await again.api.sends.first?.memory == captured)
    }

    @Test func followUpsSwitchPinnedMemoryOffAndBackOn() async throws {
        let f = try AskMemoryFixture()
        f.capture.captured = AskMemory(global: "soul")
        await f.model.prepareLauncher()
        f.model.launcherDraft.text = "Question"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 2 }
        #expect(!f.model.memorySwitchedOff(launcher: false))

        f.model.toggleMemory(launcher: false)
        #expect(f.model.memorySwitchedOff(launcher: false))
        f.model.draft.text = "Without memory"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 4 }
        // The next follow-up inherits the conversation's latest choice.
        #expect(f.model.selected?.memoryOff == true)
        #expect(f.model.memorySwitchedOff(launcher: false))

        // Switching back on is explicit, since nil means "as the conversation was".
        f.model.toggleMemory(launcher: false)
        #expect(f.model.draft.memoryOff == false)
        #expect(!f.model.memorySwitchedOff(launcher: false))
        f.model.draft.text = "With memory"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 6 }
        let sends = await f.api.sends
        #expect(sends.map(\.memoryOff) == [nil, true, nil])
        #expect(sends.dropFirst().allSatisfy { $0.memory == nil })
        #expect(f.model.selected?.memoryOff == nil)
        #expect(f.model.selected?.memory == AskMemory(global: "soul"))
    }

    @Test func followUpsWithoutPinnedMemoryNeverSendTheSwitch() async throws {
        let f = try AskMemoryFixture()
        await f.api.seed(.init(id: "plain", title: "Plain", revision: 1, updatedAt: Date(), messages: [
            .init(id: "q", role: "user", text: "Hi", createdAt: Date()),
            .init(id: "a", role: "assistant", text: "Hello", createdAt: Date())
        ]))
        await f.model.select("plain")
        f.model.draft.memoryOff = true
        f.model.draft.text = "Follow up"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.messages.count == 4 }
        #expect(await f.api.sends.first?.memoryOff == nil)
        #expect(f.model.selected?.memoryOff == nil)
    }

    @Test func memorySwitchEncodesInServerShapeOnlyWhenSet() throws {
        var request = AskDraft(text: "q").request(deviceId: "device", tools: [])
        #expect(!String(decoding: try AskCoding.encoder().encode(request), as: UTF8.self).contains("memory_off"))
        request.memoryOff = true
        #expect(String(decoding: try AskCoding.encoder().encode(request), as: UTF8.self).contains("\"memory_off\":true"))
        let json = #"{"id":"c","title":"t","revision":1,"updated_at":"2026-01-01T00:00:00.000Z","messages":[],"memory_off":true}"#
        let decoded = try AskCoding.decoder().decode(AskConversation.self, from: Data(json.utf8))
        #expect(decoded.memoryOff == true)
    }

    @Test func removedOrUnavailableMemoryIsNotReplacedByGlobalMemory() async throws {
        let f = try AskMemoryFixture()
        f.capture.global = AskMemory(global: "fallback")
        await f.model.prepareLauncher()
        #expect(f.model.launcherDraft.memory == AskMemory())
        f.model.launcherDraft.text = "Question"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected != nil }
        #expect(await f.api.sends.first?.memory == nil)
        #expect(f.model.selected?.memory == nil)
    }

    @Test func workspaceConversationsUseGlobalMemoryOnly() async throws {
        let f = try AskMemoryFixture()
        let global = AskMemory(global: "soul")
        f.capture.global = global
        f.model.newConversation()
        #expect(f.model.draft.memory == global)
        f.model.draft.text = "Question"
        f.model.submitDraft()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected != nil }
        #expect(await f.api.sends.first?.memory == global)

        // A workspace composer whose memory was never resolved falls back at submit time.
        let fresh = try AskMemoryFixture()
        fresh.capture.global = global
        fresh.model.draft = AskDraft(text: "Question")
        fresh.model.submitDraft()
        try await fresh.wait { fresh.model.busyIds.isEmpty && fresh.model.selected != nil }
        #expect(await fresh.api.sends.first?.memory == global)

        let none = try AskMemoryFixture()
        none.model.newConversation()
        #expect(none.model.draft.memory == AskMemory())
        #expect(AskConversationModel.openingMemory(nil) == nil)
        #expect(AskConversationModel.openingMemory(AskMemory()) == nil)
        #expect(AskConversationModel.openingMemory(global) == global)
    }

    @Test func clearingMemoryStripsDraftsAndPurgesServerCopies() async throws {
        let f = try AskMemoryFixture()
        let captured = AskMemory(global: "soul")
        f.capture.captured = captured
        await f.model.prepareLauncher()
        f.model.launcherDraft.text = "Question"
        f.model.submitLauncher()
        try await f.wait { f.model.busyIds.isEmpty && f.model.selected?.memory != nil }
        f.model.launcherDraft.memory = captured
        f.model.draft.memory = captured

        f.model.clearMemory()
        #expect(f.model.launcherDraft.memory == AskMemory())
        #expect(f.model.draft.memory == AskMemory())
        #expect(f.model.selected?.memory == nil)
        await f.model.waitForMemoryPurge()
        #expect(await f.api.purgeTokens == ["token"])
        #expect(!f.defaults.bool(forKey: AskConversationModel.memoryPurgePendingKey))

        // Nothing pending: flushing does not call the server again.
        f.model.flushMemoryPurge()
        await f.model.waitForMemoryPurge()
        #expect(await f.api.purgeTokens == ["token"])
    }

    @Test func failedPurgeStaysPendingUntilALaterLaunch() async throws {
        let f = try AskMemoryFixture()
        await f.api.setFailPurge(true)
        f.model.clearMemory()
        await f.model.waitForMemoryPurge()
        #expect(f.defaults.bool(forKey: AskConversationModel.memoryPurgePendingKey))
        #expect(f.model.launcherDraft.memory == nil)

        await f.api.setFailPurge(false)
        await f.model.prepareLauncher()
        await f.model.waitForMemoryPurge()
        #expect(await f.api.purgeTokens == ["token"])
        #expect(!f.defaults.bool(forKey: AskConversationModel.memoryPurgePendingKey))
    }

    @Test func clearingDuringAPurgeRunsAnotherPurge() async throws {
        let f = try AskMemoryFixture()
        f.model.clearMemory()
        f.model.clearMemory()
        await f.model.waitForMemoryPurge()
        await f.model.waitForMemoryPurge()
        #expect(await f.api.purgeTokens == ["token", "token"])
        #expect(!f.defaults.bool(forKey: AskConversationModel.memoryPurgePendingKey))
    }

    @Test func clearedMemoryCannotReturnFromOldConversationFetchOrRestoredDraft() async throws {
        let fixture = try AskMemoryFixture()
        fixture.capture.global = AskMemory(global: "stale source")
        fixture.model.draft = AskDraft(text: "Question")
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty && fixture.model.selected != nil }
        let id = try #require(fixture.model.selected?.id)
        fixture.model.clearMemory()
        await fixture.model.waitForMemoryPurge()
        // The fixture's purge records the request but intentionally retains stale server data.
        await fixture.model.select(id, reload: true)
        #expect(fixture.model.selected?.memory == nil)
        fixture.model.draft = AskDraft(text: "Next", memory: AskMemory(global: "old draft"))
        fixture.model.newConversation()
        fixture.model.draft.text = "Another question"
        fixture.model.submitDraft()
        try await fixture.wait { fixture.model.busyIds.isEmpty }
        #expect(await fixture.api.sends.last?.memory == nil)
    }

    @Test func signedOutPurgeWaitsForASession() async throws {
        let f = try AskMemoryFixture(authenticated: false)
        f.model.clearMemory()
        await f.model.waitForMemoryPurge()
        #expect(f.defaults.bool(forKey: AskConversationModel.memoryPurgePendingKey))
        #expect(await f.api.purgeTokens.isEmpty)
    }
}
