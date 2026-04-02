import XCTest
@testable import Typeflux

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
            supportedModels: ["demo-model"]
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
                additionalHeaders: ["X-Test": "1"]
            )
        )
    }
}
