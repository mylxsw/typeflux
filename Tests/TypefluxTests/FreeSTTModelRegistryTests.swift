@testable import Typeflux
import XCTest

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
            supportedModels: ["demo-stt"],
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
                additionalHeaders: ["X-Test": "1"],
            ),
        )
    }

    // MARK: - StaticFreeSTTModelSource properties

    func testStaticSourceIDAndDisplayName() {
        let source = StaticFreeSTTModelSource(
            id: "stt-id",
            displayName: "STT Source",
            baseURL: "https://stt.example.com/v1",
            supportedModels: ["whisper-large"],
        )
        XCTAssertEqual(source.id, "stt-id")
        XCTAssertEqual(source.displayName, "STT Source")
        XCTAssertEqual(source.baseURL, "https://stt.example.com/v1")
    }

    func testStaticSourceDefaultAPIKeyIsEmpty() {
        let source = StaticFreeSTTModelSource(
            id: "no-key",
            displayName: "No Key",
            baseURL: "https://example.com",
            supportedModels: ["m1"],
        )
        XCTAssertEqual(source.apiKey, "")
    }

    func testStaticSourceDefaultAdditionalHeadersIsEmpty() {
        let source = StaticFreeSTTModelSource(
            id: "no-headers",
            displayName: "No Headers",
            baseURL: "https://example.com",
            supportedModels: ["m1"],
        )
        XCTAssertTrue(source.additionalHeaders.isEmpty)
    }

    func testStaticSourceWithAPIKey() {
        let source = StaticFreeSTTModelSource(
            id: "keyed",
            displayName: "Keyed",
            baseURL: "https://api.example.com",
            apiKey: "stt-key-xyz",
            supportedModels: ["model-a"],
        )
        XCTAssertEqual(source.apiKey, "stt-key-xyz")
    }

    func testStaticSourceWithAdditionalHeaders() {
        let source = StaticFreeSTTModelSource(
            id: "hdrs",
            displayName: "Headers",
            baseURL: "https://api.example.com",
            additionalHeaders: ["X-Provider": "stt", "X-Version": "1"],
            supportedModels: ["model-b"],
        )
        XCTAssertEqual(source.additionalHeaders["X-Provider"], "stt")
        XCTAssertEqual(source.additionalHeaders["X-Version"], "1")
    }

    func testStaticSourceSupportedModels() {
        let source = StaticFreeSTTModelSource(
            id: "multi",
            displayName: "Multi STT",
            baseURL: "https://api.example.com",
            supportedModels: ["whisper-tiny", "whisper-small", "whisper-medium"],
        )
        XCTAssertEqual(source.supportedModels, ["whisper-tiny", "whisper-small", "whisper-medium"])
    }

    // MARK: - resolve() behavior

    func testResolveReturnsNilForUnknownModel() {
        let source = StaticFreeSTTModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["known-stt"],
        )
        XCTAssertNil(source.resolve(modelName: "unknown-stt"))
    }

    func testResolveReturnsNilForEmptyModelName() {
        let source = StaticFreeSTTModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["model-a"],
        )
        XCTAssertNil(source.resolve(modelName: ""))
    }

    func testResolveReturnsNilForWhitespaceOnlyModelName() {
        let source = StaticFreeSTTModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["model-a"],
        )
        XCTAssertNil(source.resolve(modelName: "  "))
    }

    func testResolvePreservesOriginalModelCasingFromSource() throws {
        let source = StaticFreeSTTModelSource(
            id: "src",
            displayName: "Source",
            baseURL: "https://example.com",
            supportedModels: ["Whisper-Large-V3"],
        )
        let resolved = try XCTUnwrap(source.resolve(modelName: "whisper-large-v3"))
        XCTAssertEqual(resolved.modelName, "Whisper-Large-V3")
    }

    func testResolvePopulatesAllFields() throws {
        let source = StaticFreeSTTModelSource(
            id: "full-stt",
            displayName: "Full STT",
            baseURL: "https://stt.full.com/v1",
            apiKey: "sk-stt-abc",
            additionalHeaders: ["X-H": "val"],
            supportedModels: ["full-stt-model"],
        )
        let resolved = try XCTUnwrap(source.resolve(modelName: "full-stt-model"))
        XCTAssertEqual(resolved.sourceID, "full-stt")
        XCTAssertEqual(resolved.sourceName, "Full STT")
        XCTAssertEqual(resolved.baseURL, "https://stt.full.com/v1")
        XCTAssertEqual(resolved.modelName, "full-stt-model")
        XCTAssertEqual(resolved.apiKey, "sk-stt-abc")
        XCTAssertEqual(resolved.additionalHeaders["X-H"], "val")
    }

    // MARK: - sourceSummaryLines

    func testSourceSummaryLinesReturnsEmptyWhenNoSources() {
        let lines = FreeSTTModelRegistry.sourceSummaryLines()
        XCTAssertTrue(lines.isEmpty)
    }

    // MARK: - FreeSTTResolvedModel equality

    func testFreeSTTResolvedModelEquality() {
        let m1 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://a.com",
            modelName: "m", apiKey: "", additionalHeaders: [:],
        )
        let m2 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://a.com",
            modelName: "m", apiKey: "", additionalHeaders: [:],
        )
        XCTAssertEqual(m1, m2)
    }

    func testFreeSTTResolvedModelInequalityOnBaseURL() {
        let m1 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://a.com",
            modelName: "m", apiKey: "", additionalHeaders: [:],
        )
        let m2 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://b.com",
            modelName: "m", apiKey: "", additionalHeaders: [:],
        )
        XCTAssertNotEqual(m1, m2)
    }

    func testFreeSTTResolvedModelInequalityOnModelName() {
        let m1 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://a.com",
            modelName: "model-a", apiKey: "", additionalHeaders: [:],
        )
        let m2 = FreeSTTResolvedModel(
            sourceID: "s1", sourceName: "S1", baseURL: "https://a.com",
            modelName: "model-b", apiKey: "", additionalHeaders: [:],
        )
        XCTAssertNotEqual(m1, m2)
    }
}
