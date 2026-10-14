import Foundation
import Testing
@testable import Typeflux

@Suite("Translation engine injection", .exclusiveUIState)
struct AskTranslationEngineFactoryTests {
    @Test func independentAIModelsKeepTheirReferencesAndReuseTheirOwnCaches() async throws {
        let defaults = UserDefaults(suiteName: "TranslationFactory-" + UUID().uuidString)!
        let settings = SettingsStore(defaults: defaults)
        let llm = AskTestLLMService()
        llm.answer = "Bonjour"
        let factory = AskTranslationEngineFactory(settings: settings, textProcessing: llm,
                                                  credentials: AskTestTranslationCredentials())
        let follows = try #require(factory.engine(for: .ai()) as? AskAITranslationEngine)
        #expect(try follows === #require(factory.engine(for: .ai(id: "another")) as? AskAITranslationEngine))
        let removed = try #require(factory.engine(for: .ai(
            id: "removed",
            modelReference: "custom:removed"
        )) as? AskAITranslationEngine)
        #expect(removed !== follows)
        await #expect(throws: AskPluginFailure.self) { try await removed.translate("hello", from: "en", to: "fr") }
        #expect(try await follows.translate("hello", from: "en", to: "fr") == "Bonjour")
        var streamed = ""
        for try await part in follows.streamTranslation("hello", from: "en", to: "fr") {
            streamed += part
        }
        #expect(streamed == "Bonjour")
        #expect(factory.name(for: .ai(id: "removed", modelReference: "custom:removed")) == AskPluginRegistry
            .sourceLabel(L("ask.models.unavailable")))
        #expect(factory.name(for: .device) == L("ask.translation.stack.deviceTitle"))
        for provider in AskTranslationProvider.allCases {
            #expect(factory.name(for: .provider(provider)) == provider.title)
            let engine = try #require(factory.engine(for: .provider(provider)) as? AskServiceTranslationEngine)
            #expect(!engine.isConfigured && engine.provider == provider)
        }
        #expect(await factory.engine(for: .device).canTranslate(from: nil, to: "en") == false)
        for index in 0 ..< 34 {
            _ = factory.engine(for: .ai(id: "\(index)", modelReference: "missing:\(index)"))
        }
        #expect(factory.name(for: .ai()).hasPrefix("AI"))
        let session = await factory.makeSession()
        let result = try await session.run(.init(text: "A sentence.", source: "en", target: "fr", interface: .english,
                                                 services: [.ai()], submitted: true),
                                           engine: { factory.engine(for: $0) },
                                           name: { factory.name(for: $0) })
        #expect(result.first?.completedText == "Bonjour")
    }

    @Test func emptyStreamingAITranslationFailsOnlyItsItem() async throws {
        let llm = AskTestLLMService()
        llm.answer = "   "
        let engine = AskAITranslationEngine(service: llm) { "test" }
        let coordinator = await MainActor.run { AskTranslationFanout() }
        let results = try await coordinator.run(
            .init(text: "A sentence.", source: "en", target: "fr", interface: .english,
                  services: [.ai()], submitted: true),
            engine: { _ in engine },
            name: { _ in "test" }
        )
        if case let .failed(failure) = results.first?.state {
            #expect(failure.recovery == .retry)
        } else {
            Issue.record("Empty stream succeeded")
        }
    }
}
