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

final class TypefluxCloudFeatureTests: XCTestCase {
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
