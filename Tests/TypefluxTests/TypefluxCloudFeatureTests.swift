import Foundation
import XCTest
@testable import Typeflux

private struct FeatureEchoService: LLMService {
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        await Task.yield()
        return LLMFeatureContext.feature?.rawValue ?? "unset"
    }
    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        try await complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

private struct DictionaryEchoService: LLMService {
    func streamRewrite(request: LLMRewriteRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        await Task.yield()
        let languages = LLMFeatureContext.dictionary
        return "\(languages?.source ?? "und"):\(languages?.target ?? "unset"):\(LLMFeatureContext.feature?.rawValue ?? "unset")"
    }
    func completeJSON(systemPrompt: String, userPrompt: String, schema: LLMJSONSchema) async throws -> String {
        let text = try await complete(systemPrompt: systemPrompt, userPrompt: userPrompt)
        return #"{"kind":"text","translation":"\#(text)"}"#
    }
}

final class TypefluxCloudFeatureTests: XCTestCase {
    func testDictionaryHeadersAreOnlySentForCloudTranslationFeatures() {
        LLMFeatureContext.$dictionary.withValue(.init(source: "en", target: "zh-Hans")) {
            for feature in TypefluxCloudFeature.allCases {
                let cloud = ResolvedLLMConnection(provider: .typefluxCloud, baseURL: URL(string: "https://example.invalid")!, model: "default", apiKey: "", additionalHeaders: [:])
                let headers = cloud.headers(for: .automaticVocabulary, feature: feature)
                if feature == .translation || feature == .wordCard {
                    XCTAssertEqual(headers["X-Typeflux-Dictionary-Version"], "1")
                    XCTAssertEqual(headers["X-Typeflux-Dictionary-Source-Language"], "en")
                    XCTAssertEqual(headers["X-Typeflux-Dictionary-Target-Language"], "zh-Hans")
                } else {
                    XCTAssertNil(headers["X-Typeflux-Dictionary-Version"])
                }
            }
            for provider in [LLMRemoteProvider.custom, .openAI, .freeModel] {
                let connection = ResolvedLLMConnection(provider: provider, baseURL: URL(string: "http://localhost:11434/v1")!, model: "local", apiKey: "", additionalHeaders: [:])
                XCTAssertNil(connection.headers(for: .askAnything, feature: .translation)["X-Typeflux-Dictionary-Version"])
            }
        }
        LLMFeatureContext.$dictionary.withValue(.init(source: nil, target: "fr")) {
            let cloud = ResolvedLLMConnection(provider: .typefluxCloud, baseURL: URL(string: "https://example.invalid")!, model: "default", apiKey: "", additionalHeaders: [:])
            XCTAssertEqual(cloud.headers(for: .askAnything, feature: .translation)["X-Typeflux-Dictionary-Source-Language"], "und")
        }
        XCTAssertNil(LLMFeatureContext.dictionary)
    }

    func testDictionaryLanguagesSurviveTranslationWordCardAndStreamingCalls() async throws {
        let engine = AskAITranslationEngine(service: DictionaryEchoService()) { "test" }
        let text = try await engine.translate("hello", from: "en", to: "fr")
        XCTAssertEqual(text, "en:fr:translation")
        let card = try await engine.lookUp("hello", from: "en", to: "ja", generation: "0")
        XCTAssertEqual(card, .translation("en:ja:word-card"))
        var streamed = ""
        for try await piece in engine.streamTranslation("hello", from: nil, to: "de") { streamed += piece }
        XCTAssertEqual(streamed, "und:de:translation")
        XCTAssertNil(LLMFeatureContext.dictionary)
        XCTAssertNil(LLMFeatureContext.feature)
    }

    func testConcurrentDictionaryLookupsKeepLanguagePairsSeparate() async throws {
        let engine = AskAITranslationEngine(service: DictionaryEchoService()) { "test" }
        async let french = engine.translate("hello", from: "en", to: "fr")
        async let japanese = engine.translate("hello", from: "en", to: "ja")
        let results = try await (french, japanese)
        XCTAssertEqual(results.0, "en:fr:translation")
        XCTAssertEqual(results.1, "en:ja:translation")
        XCTAssertNil(LLMFeatureContext.dictionary)
    }

    func testFeatureScopeSurvivesSuspensionWithoutLeakingBetweenTasks() async throws {
        let service = FeatureEchoService()
        async let translation = service.complete(systemPrompt: "", userPrompt: "", feature: .translation)
        async let memory = service.completeJSON(systemPrompt: "", userPrompt: "", schema: .init(name: "test", schema: [:]), feature: .memoryConsolidation)
        let values = try await (translation, memory)
        XCTAssertEqual(values.0, "translation")
        XCTAssertEqual(values.1, "memory-consolidation")
        XCTAssertNil(LLMFeatureContext.feature)
        let unscoped = try await service.complete(systemPrompt: "", userPrompt: "")
        XCTAssertEqual(unscoped, "unset")
    }

    func testTranslationStreamKeepsItsFeatureScope() async throws {
        let engine = AskAITranslationEngine(service: FeatureEchoService()) { "test" }
        var text = ""
        for try await piece in engine.streamTranslation("Hello.", from: "en", to: "fr") { text += piece }
        XCTAssertEqual(text, "translation")
        XCTAssertNil(LLMFeatureContext.feature)
    }

    func testOnlyCloudEmitsFeatureAndKeepsHistoricalScenario() throws {
        for feature in TypefluxCloudFeature.allCases {
            let connection = ResolvedLLMConnection(provider: .typefluxCloud, baseURL: URL(string: "https://example.invalid")!, model: "default", apiKey: "token", additionalHeaders: [:])
            let headers = connection.headers(for: .automaticVocabulary, feature: feature)
            XCTAssertEqual(headers[TypefluxCloudRequestHeaders.featureField], feature.rawValue)
            XCTAssertEqual(headers[TypefluxCloudRequestHeaders.scenarioField], "automatic-vocabulary")
            XCTAssertEqual(headers["X-Typeflux-Model-Catalog"], "1")
        }
        let custom = ResolvedLLMConnection(provider: .custom, baseURL: URL(string: "https://example.invalid")!, model: "m", apiKey: "key", additionalHeaders: [:])
        XCTAssertNil(custom.headers(for: .automaticVocabulary, feature: .wordCard)[TypefluxCloudRequestHeaders.featureField])
    }

    @MainActor
    func testTextDiscoveryDoesNotExposeTextOnlyModelsInAsk() throws {
        let suite = "feature-discovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.replaceCloudModels([.init(id: "default", name: "Ask", scenarios: ["ask"])])
        try library.replaceRewriteModels([.init(id: "default", name: "Fast text", scenarios: ["rewrite"]), .init(id: "text", name: "Text", scenarios: ["rewrite"])])
        XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.map(\.id), ["default"])
        XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false, scenario: "rewrite").first(where: \.isCloud)?.models.map(\.id), ["default", "text"])
        XCTAssertEqual(library.name(for: "cloud:default", scenario: "rewrite"), "Fast text")
        library.rewriteReference = "cloud:text"
        XCTAssertEqual(library.settings.textLLMConfiguration().model, "cloud:text")
        try library.replaceRewriteModels([])
        XCTAssertNil(library.selectableProviders(loggedIn: true, hasImage: false, scenario: "rewrite").first(where: \.isCloud))
        try library.replaceRewriteModels(nil)
        XCTAssertEqual(library.name(for: "cloud:default", scenario: "rewrite"), "Typeflux Cloud")
    }
}
