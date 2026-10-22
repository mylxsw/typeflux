import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeatureTranslationTests {
    @Test func streamingTransferKeepsResultsAndDoesNotRepeatProviderCalls() throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model, id = UUID()
        let original = AskPluginOutput(body: "First", original: "Source text", meta: [], source: "AI", actions: [],
            translation: .init(results: [], source: "en", target: "zh-Hans", interface: .english, submitted: true, isLookup: false))
        let first = FeatureTranslationTransfer(id: id, source: .launcher, sequence: 0, initial: true,
            running: true, failed: false, engine: nil, output: .init(original))
        let decoded = try JSONDecoder().decode(FeatureTranslationTransfer.self, from: JSONEncoder().encode(first))
        #expect(model.receiveFeatureTransfer(decoded))
        #expect(model.text == "Source text" && model.running)
        #expect(fixture.ai.requests.isEmpty && fixture.device.requests.isEmpty)
        var final = original
        final.body = "Final answer"
        let done = FeatureTranslationTransfer(id: id, source: .launcher, sequence: 1, initial: false,
            running: false, failed: false, engine: nil, output: .init(final))
        #expect(model.receiveFeatureTransfer(done))
        #expect(model.output?.body == "Final answer" && !model.running)
        #expect(model.receiveFeatureTransfer(first))
        #expect(model.output?.body == "Final answer")
        #expect(fixture.ai.requests.isEmpty && fixture.device.requests.isEmpty)
    }

    @Test func editingRejectsLateUpdatesWithoutOverwritingNewInput() {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        let model = fixture.model, id = UUID()
        let output = AskPluginOutput(body: "Partial", original: "Source", meta: [], source: "AI", actions: [])
        let first = FeatureTranslationTransfer(id: id, source: .launcher, sequence: 0, initial: true,
            running: true, failed: false, engine: nil, output: .init(output))
        #expect(model.receiveFeatureTransfer(first))
        model.text = "New question"
        #expect(!model.receiveFeatureTransfer(.init(id: id, source: .launcher, sequence: 1, initial: false,
            running: false, failed: false, engine: nil, output: .init(output))))
        #expect(model.text == "New question")
    }

    @Test func sourceStreamSurvivesLostAcknowledgementAndRetriesWithoutAnotherProviderCall() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        fixture.device.delay = .milliseconds(250)
        var plugin = fixture.model.plugin
        plugin.fanout = AskTranslationFanout()
        let session = AskPluginSession(plugins: [plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "A source translation sentence.", selection: nil, language: .english)
        for _ in 0..<200 where !session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        var accepted = 0, failures = 0, loseReply = true
        var ids: Set<UUID> = []
        let bridge = FeatureTranslationBridge(route: { command in
            if command.action == "ping" { return Data() }
            let transfer = try JSONDecoder().decode(FeatureTranslationTransfer.self, from: command.payload)
            ids.insert(transfer.id)
            let result = fixture.model.receiveFeatureTransfer(transfer)
            if loseReply { throw FeatureRPC.Failure.timedOut }
            return try JSONEncoder().encode(result)
        })
        #expect(bridge.move(session, accepted: { accepted += 1 }, failed: { failures += 1 }))
        for _ in 0..<200 where failures == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(accepted == 0)
        loseReply = false
        #expect(bridge.move(session, accepted: { accepted += 1 }, failed: { failures += 1 }))
        for _ in 0..<200 where accepted == 0 || fixture.model.running { try await Task.sleep(for: .milliseconds(5)) }
        #expect(accepted == 1 && ids.count == 1)
        #expect(fixture.device.requests.count == 1 && fixture.ai.requests.isEmpty)
        #expect(fixture.model.output?.translation?.results.first?.completedText == "Device answer")
        bridge.cancel("not-an-id")
    }

    @Test func unavailableDestinationKeepsSourceSessionOwnedAndRunning() async throws {
        let fixture = TranslationPanelFixture()
        defer { fixture.clean() }
        fixture.device.delay = .milliseconds(250)
        let session = AskPluginSession(plugins: [fixture.model.plugin]) { AskTranslatePlugin.keywords }
        session.debounce = .zero
        session.enter(AskTranslatePlugin.keywords[0])
        session.update(text: "Keep this source sentence.", selection: nil, language: .english)
        for _ in 0..<200 where !session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        var failures = 0
        let bridge = FeatureTranslationBridge(route: { _ in throw FeatureRPC.Failure.unavailable })
        #expect(bridge.move(session, accepted: { Issue.record("The destination never accepted this input") }, failed: { failures += 1 }))
        for _ in 0..<200 where failures == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.isPlanCurrent && session.isRunning)
        session.deactivate()
    }

    @Test func modelPreferencesRefreshAcrossIndependentLibraries() throws {
        let suite = "feature-model-preferences-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let reader = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        writer.defaultReference = "cloud:new-model"
        writer.rewriteReference = "cloud:rewrite"
        try writer.replaceCloudModels([.init(id: "new-model", name: "New model")])
        reader.reloadFeaturePreferences()
        #expect(reader.registry == writer.registry)
        #expect(reader.defaultReference == writer.defaultReference && reader.rewriteReference == writer.rewriteReference)
        reader.reloadFeaturePreferences()
        #expect(reader.registry == writer.registry)
    }
}
