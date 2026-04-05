@testable import Typeflux
import XCTest

final class FreeLLMModelRegistryTests: XCTestCase {
    func testRegistryStartsEmptyUntilConcreteSourcesAreAdded() {
        XCTAssertTrue(FreeLLMModelRegistry.sources.isEmpty)
        XCTAssertTrue(FreeLLMModelRegistry.suggestedModelNames.isEmpty)
        XCTAssertNil(FreeLLMModelRegistry.resolve(modelName: "any-model"))
    }

    func testStaticSourceResolvesModelCaseInsensitively() throws {
        let source = StaticFreeLLMModelSource(
            id: "demo",
            displayName: "Demo Free Source",
            baseURL: "https://example.com/v1",
            additionalHeaders: ["X-Test": "1"],
            supportedModels: ["demo-model"],
        )

        let resolved = try XCTUnwrap(source.resolve(modelName: "DEMO-MODEL"))
        XCTAssertEqual(
            resolved,
            FreeLLMResolvedModel(
                sourceID: "demo",
                sourceName: "Demo Free Source",
                baseURL: "https://example.com/v1",
                modelName: "demo-model",
                apiKey: "",
                additionalHeaders: ["X-Test": "1"],
            ),
        )
    }

    // MARK: - StaticFreeLLMModelSource properties

    func testStaticSourceIDAndDisplayName() {
        let source = StaticFreeLLMModelSource(
            id: "test-id",
            displayName: "Test Source",
            baseURL: "https://api.test.com/v1",
            supportedModels: ["model-a"],
        )
        XCTAssertEqual(source.id, "test-id")
        XCTAssertEqual(source.displayName, "Test Source")
        XCTAssertEqual(source.baseURL, "https://api.test.com/v1")
    }

    func testStaticSourceDefaultAPIKeyIsEmpty() {
        let source = StaticFreeLLMModelSource(
            id: "empty-key",
            displayName: "No Key Source",
            baseURL: "https://example.com",
            supportedModels: ["m1"],
        )
        XCTAssertEqual(source.apiKey, "")
    }

    func testStaticSourceDefaultAdditionalHeadersIsEmpty() {
        let source = StaticFreeLLMModelSource(
            id: "no-headers",
            displayName: "No Headers",
            baseURL: "https://example.com",
            supportedModels: ["m1"],
        )
        XCTAssertTrue(source.additionalHeaders.isEmpty)
    }

    func testStaticSourceWithAPIKey() {
        let source = StaticFreeLLMModelSource(
            id: "with-key",
            displayName: "Keyed Source",
            baseURL: "https://api.example.com",
            apiKey: "sk-1234",
            supportedModels: ["model-b"],
        )
        XCTAssertEqual(source.apiKey, "sk-1234")
    }

    func testStaticSourceWithAdditionalHeaders() {
        let source = StaticFreeLLMModelSource(
            id: "with-headers",
            displayName: "Headers Source",
            baseURL: "https://api.example.com",
            additionalHeaders: ["X-Custom": "value", "X-Version": "2"],
            supportedModels: ["model-c"],
        )
        XCTAssertEqual(source.additionalHeaders["X-Custom"], "value")
        XCTAssertEqual(source.additionalHeaders["X-Version"], "2")
    }

    func testStaticSourceSupportedModels() {
        let source = StaticFreeLLMModelSource(
            id: "multi",
            displayName: "Multi Model",
            baseURL: "https://api.example.com",
            supportedModels: ["model-a", "model-b", "model-c"],
        )
        XCTAssertEqual(source.supportedModels, ["model-a", "model-b", "model-c"])
    }

    // MARK: - resolve() behavior

    func testResolveReturnsNilForUnknownModel() {
        let source = StaticFreeLLMModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["known-model"],
        )
        XCTAssertNil(source.resolve(modelName: "unknown-model"))
    }

    func testResolveReturnsNilForEmptyModelName() {
        let source = StaticFreeLLMModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["model-a"],
        )
        XCTAssertNil(source.resolve(modelName: ""))
    }

    func testResolveReturnsNilForWhitespaceOnlyModelName() {
        let source = StaticFreeLLMModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["model-a"],
        )
        XCTAssertNil(source.resolve(modelName: "   "))
    }

    func testResolvePreservesOriginalModelCasingFromSource() throws {
        let source = StaticFreeLLMModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["GPT-4o-mini"],
        )
        let resolved = try XCTUnwrap(source.resolve(modelName: "gpt-4o-mini"))
        // The original model name (from source list) is preserved
        XCTAssertEqual(resolved.modelName, "GPT-4o-mini")
    }

    func testResolvePopulatesAllFields() throws {
        let source = StaticFreeLLMModelSource(
            id: "full-src",
            displayName: "Full Source",
            baseURL: "https://api.full.com/v1",
            apiKey: "sk-abc",
            additionalHeaders: ["H": "V"],
            supportedModels: ["full-model"],
        )
        let resolved = try XCTUnwrap(source.resolve(modelName: "full-model"))
        XCTAssertEqual(resolved.sourceID, "full-src")
        XCTAssertEqual(resolved.sourceName, "Full Source")
        XCTAssertEqual(resolved.baseURL, "https://api.full.com/v1")
        XCTAssertEqual(resolved.modelName, "full-model")
        XCTAssertEqual(resolved.apiKey, "sk-abc")
        XCTAssertEqual(resolved.additionalHeaders["H"], "V")
    }

    // MARK: - sourceSummaryLines

    func testSourceSummaryLinesReturnsEmptyWhenNoSources() {
        let lines = FreeLLMModelRegistry.sourceSummaryLines()
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: - FreeLLMResolvedModel equality

    func testFreeLLMResolvedModelEquality() {
        let model1 = FreeLLMResolvedModel(
            sourceID: "s1",
            sourceName: "Source 1",
            baseURL: "https://example.com",
            modelName: "model-a",
            apiKey: "key1",
            additionalHeaders: [:],
        )
        let model2 = FreeLLMResolvedModel(
            sourceID: "s1",
            sourceName: "Source 1",
            baseURL: "https://example.com",
            modelName: "model-a",
            apiKey: "key1",
            additionalHeaders: [:],
        )
        XCTAssertEqual(model1, model2)
    }

    func testFreeLLMResolvedModelInequalityOnSourceID() {
        let model1 = FreeLLMResolvedModel(
            sourceID: "s1",
            sourceName: "Source 1",
            baseURL: "https://example.com",
            modelName: "model-a",
            apiKey: "key1",
            additionalHeaders: [:],
        )
        let model2 = FreeLLMResolvedModel(
            sourceID: "s2",
            sourceName: "Source 1",
            baseURL: "https://example.com",
            modelName: "model-a",
            apiKey: "key1",
            additionalHeaders: [:],
        )
        XCTAssertNotEqual(model1, model2)
    }

    func testFreeLLMResolvedModelInequalityOnModelName() {
        let model1 = FreeLLMResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://example.com",
            modelName: "model-a", apiKey: "", additionalHeaders: [:],
        )
        let model2 = FreeLLMResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://example.com",
            modelName: "model-b", apiKey: "", additionalHeaders: [:],
        )
        XCTAssertNotEqual(model1, model2)
    }

    func testFreeLLMResolvedModelInequalityOnAPIKey() {
        let model1 = FreeLLMResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://example.com",
            modelName: "model-a", apiKey: "key1", additionalHeaders: [:],
        )
        let model2 = FreeLLMResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://example.com",
            modelName: "model-a", apiKey: "key2", additionalHeaders: [:],
        )
        XCTAssertNotEqual(model1, model2)
    }
}
