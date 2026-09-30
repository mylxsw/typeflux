@testable import Typeflux
import XCTest

final class CloudModelPricingTests: XCTestCase {
    func testOldCatalogHasNoAssumedPrice() throws {
        let model = try AskCoding.decoder().decode(AskCloudModel.self, from: Data(#"{"id":"default","name":"Cloud"}"#.utf8))
        XCTAssertEqual(model.registered.vision, true)
        XCTAssertNil(model.pricing)
        XCTAssertEqual(model.registered.displayName, "Cloud")
        XCTAssertNil(model.scenarios)
    }

    func testCatalogMetadataAndPriceSurviveRegistryRoundTrip() throws {
        let raw = #"{"id":"deep","name":"Deep","scenarios":["ask"],"vision":true,"context_window_tokens":128000,"max_output_tokens":8192,"model_version":3,"pricing":{"multiplier":"0.5000","base_rate_version":"v2","unit":"credit"}}"#
        let model = try AskCoding.decoder().decode(AskCloudModel.self, from: Data(raw.utf8))
        XCTAssertEqual(model.pricing?.label, "0.5X")
        XCTAssertEqual(model.pricing?.baseRateVersion, "v2")
        XCTAssertEqual(model.contextWindowTokens, 128000)
        XCTAssertEqual(model.maxOutputTokens, 8192)
        XCTAssertEqual(model.modelVersion, 3)
        XCTAssertEqual(model.registered.displayName, "Deep · 0.5X")
        let registered = try JSONDecoder().decode(RegisteredModel.self, from: JSONEncoder().encode(model.registered))
        XCTAssertEqual(registered, model.registered)
    }

    func testMalformedPricesAreNotDisplayedAsValidMultipliers() {
        for value in ["", "0", "-1", "101", "nan", "0.5garbage", "1e5"] {
            XCTAssertNil(CloudModelPricing(multiplier: value).label, value)
        }
        XCTAssertEqual(CloudModelPricing(multiplier: "2").label, "2X")
        XCTAssertEqual(CloudModelPricing(multiplier: "1.0000").label, "1X")
    }

    @MainActor
    func testScenarioFilteringAndUnavailableSelection() throws {
        let suite = "cloud-pricing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.removeModel("cloud:default", providerID: "typefluxCloud")
        try library.addModels([
            .init(id: "ask", name: "Ask", reference: "cloud:ask", vision: true, scenarios: ["ask"]),
            .init(id: "rewrite", name: "Rewrite", reference: "cloud:rewrite", scenarios: ["rewrite"]),
        ], providerID: "typefluxCloud")
        let ask = library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)
        XCTAssertEqual(ask?.models.map(\.id), ["ask"])
        let rewrite = library.selectableProviders(loggedIn: true, hasImage: false, scenario: "rewrite").first(where: \.isCloud)
        XCTAssertEqual(rewrite?.models.map(\.id), ["default"])
        XCTAssertNil(rewrite?.models.first?.pricing)
        XCTAssertEqual(library.name(for: "cloud:default", scenario: "rewrite"), "Typeflux Cloud")
        library.defaultReference = "cloud:missing"
        XCTAssertEqual(library.name(for: library.defaultReference), L("ask.models.unavailable"))
        XCTAssertEqual(library.defaultReference, "cloud:missing")
    }
}
