import XCTest
@testable import Typeflux

final class FreeSTTModelRegistryTests: XCTestCase {
    func testRegistryStartsEmptyUntilConcreteSourcesAreAdded() {
        XCTAssertTrue(FreeSTTModelRegistry.sources.isEmpty)
        XCTAssertTrue(FreeSTTModelRegistry.suggestedModelNames.isEmpty)
        XCTAssertNil(FreeSTTModelRegistry.resolve(modelName: "any-model"))
    }

    func testStaticSourceResolvesModelCaseInsensitively() throws {
        let source = StaticFreeSTTModelSource(
            id: "demo",
            displayName: "Demo Free STT",
            baseURL: "https://example.com/v1",
            additionalHeaders: ["X-Test": "1"],
            supportedModels: ["demo-stt"]
        )

        let resolved = try XCTUnwrap(source.resolve(modelName: "DEMO-STT"))
        XCTAssertEqual(
            resolved,
            FreeSTTResolvedModel(
                sourceID: "demo",
                sourceName: "Demo Free STT",
                baseURL: "https://example.com/v1",
                modelName: "demo-stt",
                apiKey: "",
                additionalHeaders: ["X-Test": "1"]
            )
        )
    }
}
