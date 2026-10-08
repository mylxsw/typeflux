@testable import Typeflux
import XCTest

@MainActor
final class CloudModelAliasTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "cloud-alias-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func library(_ models: [AskCloudModel] = CloudModelAliasFixture.models) throws -> AskModelLibrary {
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.replaceCloudModels(models)
        return library
    }

    func testPickerShowsOnlyConfiguredModelsWithDeepSeekIcons() throws {
        let library = try library()
        let provider = try XCTUnwrap(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud))
        XCTAssertEqual(provider.models.map(\.id), CloudModelAliasFixture.models.dropFirst().map(\.id))
        XCTAssertEqual(provider.models.count, 5)
        let deepSeek = provider.models.filter { $0.name.hasPrefix("DeepSeek") }
        XCTAssertEqual(deepSeek.map(\.name), ["DeepSeek Pro", "DeepSeek Flash"])
        for model in deepSeek {
            let icon = ModelIcon(model: model, provider: provider)
            XCTAssertEqual(icon.descriptor.resourceKey, "deepseek")
            for dark in [false, true] {
                XCTAssertNotNil(ModelIcon.image(for: icon.descriptor, dark: dark))
            }
        }
    }

    func testLegacySelectionUsesExplicitModelForPresentationWithoutChangingRouting() throws {
        let library = try library()
        let displayed = library.presentationReference(for: "cloud:default")
        XCTAssertEqual(displayed, "cloud:deployment-pro")
        XCTAssertEqual(library.defaultReference, "cloud:default")
        XCTAssertNotNil(library.registry.resolve("cloud:default"))
        XCTAssertEqual(library.cloud, CloudModelAliasFixture.models)
        XCTAssertEqual(library.presentationReference(for: "cloud:deployment-flash"), "cloud:deployment-flash")
        let (provider, model) = try XCTUnwrap(library.registry.resolve(displayed))
        XCTAssertEqual(ModelIcon(model: model, provider: provider).descriptor.resourceKey, "deepseek")
        XCTAssertNil(library.selectionReason(model, provider: provider, hasImage: false, loggedIn: true))
        XCTAssertFalse(AskModelChoices.offersMakeDefault(showsDefaultAction: true, selectionAvailable: true,
                                                        reference: displayed,
                                                        defaultReference: library.presentationReference(for: library.defaultReference)))
    }

    func testPersistedCatalogIsDeduplicatedBeforeRefresh() throws {
        _ = try library()
        let restored = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertEqual(restored.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.count, 5)
        XCTAssertEqual(restored.presentationReference(for: "cloud:default"), "cloud:deployment-pro")
        XCTAssertNotNil(restored.registry.resolve("cloud:default"))
    }

    func testDefaultChangeUpdatesPresentationAndPreservesUserDefault() throws {
        let library = try library()
        library.defaultReference = "cloud:deployment-pro"
        var models = CloudModelAliasFixture.models
        models[0] = models[2]
        models[0].id = "default"
        try library.replaceCloudModels(models)
        XCTAssertEqual(library.presentationReference(for: "cloud:default"), "cloud:deployment-flash")
        XCTAssertEqual(library.defaultReference, "cloud:deployment-pro")
        XCTAssertEqual(library.presentationReference(for: library.defaultReference), "cloud:deployment-pro")
        XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.count, 5)
    }

    func testImageFilteringAndRewriteRemainIndependent() throws {
        let library = try library()
        let vision = try XCTUnwrap(library.selectableProviders(loggedIn: true, hasImage: true).first(where: \.isCloud))
        XCTAssertEqual(vision.models.map(\.name), ["Claude Sonnet", "Claude Haiku", "MiniMax M3"])
        XCTAssertFalse(vision.models.contains { $0.reference == library.presentationReference(for: "cloud:default") })
        XCTAssertNil(library.selectableProviders(loggedIn: false, hasImage: false).first(where: \.isCloud))
        let rewrite = try XCTUnwrap(library.selectableProviders(loggedIn: true, hasImage: false, scenario: "rewrite").first(where: \.isCloud))
        XCTAssertEqual(rewrite.models.map(\.id), ["default"])
        XCTAssertEqual(rewrite.models.first?.name, "Typeflux Cloud")
        XCTAssertEqual(library.presentationReference(for: "cloud:default", scenario: "rewrite"), "cloud:default")
    }

    func testLegacyDefaultOnlyCatalogRemainsSelectable() throws {
        let library = try library([.init(id: "default", name: "Typeflux Cloud")])
        XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.map(\.id), ["default"])
        XCTAssertEqual(library.presentationReference(for: "cloud:default"), "cloud:default")
        try library.replaceCloudModels([])
        XCTAssertNil(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud))
        XCTAssertEqual(library.presentationReference(for: "cloud:default"), "cloud:default")
    }

    func testDiscoveredRewriteModelsRemainIndependentOfAskAlias() throws {
        let library = try library()
        try library.replaceRewriteModels([
            .init(id: "default", name: "Fast text", scenarios: ["rewrite"]),
            .init(id: "text", name: "Text", scenarios: ["rewrite"]),
        ])
        let restored = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        XCTAssertEqual(restored.presentationReference(for: "cloud:default"), "cloud:deployment-pro")
        XCTAssertEqual(restored.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.count, 5)
        XCTAssertEqual(restored.presentationReference(for: "cloud:default", scenario: "rewrite"), "cloud:default")
        XCTAssertEqual(restored.name(for: "cloud:default", scenario: "rewrite"), "Fast text")
        XCTAssertEqual(restored.selectableProviders(loggedIn: true, hasImage: false, scenario: "rewrite")
            .first(where: \.isCloud)?.models.map(\.id), ["default", "text"])
    }

    func testSameNameWithDifferentMetadataDoesNotHideDefaultRoute() throws {
        let original = CloudModelAliasFixture.models[1]
        var variants = [AskCloudModel]()
        var price = original; price.pricing = .init(multiplier: "1"); variants.append(price)
        var vision = original; vision.vision = true; variants.append(vision)
        var limit = original; limit.maxOutputTokens = 4096; variants.append(limit)
        var reasoning = original; reasoning.capabilities = ["reasoning": true]; variants.append(reasoning)
        var efforts = original; efforts.reasoningEfforts = ["low", "high"]; variants.append(efforts)
        for model in variants {
            let library = try library([CloudModelAliasFixture.models[0], model])
            XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.count, 2)
            XCTAssertEqual(library.presentationReference(for: "cloud:default"), "cloud:default")
        }
    }

    func testAmbiguousMatchesPreserveEveryExplicitModel() throws {
        var another = CloudModelAliasFixture.models[1]
        another.id = "another-pro-deployment"
        let library = try library(CloudModelAliasFixture.models + [another])
        XCTAssertEqual(library.selectableProviders(loggedIn: true, hasImage: false).first(where: \.isCloud)?.models.count, 7)
        XCTAssertEqual(library.presentationReference(for: "cloud:default"), "cloud:default")
    }
}

enum CloudModelAliasFixture {
    static var models: [AskCloudModel] {
        let pro = model("deployment-pro", "DeepSeek Pro", "5", vision: false)
        var alias = pro
        alias.id = "default"
        return [alias, pro,
                model("deployment-flash", "DeepSeek Flash", "1", vision: false),
                model("deployment-sonnet", "Claude Sonnet", "8", vision: true),
                model("deployment-haiku", "Claude Haiku", "5", vision: true),
                model("deployment-minimax", "MiniMax M3", "1", vision: true)]
    }

    private static func model(_ id: String, _ name: String, _ multiplier: String, vision: Bool) -> AskCloudModel {
        .init(id: id, name: name, vision: vision, scenarios: ["ask"],
              contextWindowTokens: 204800, maxOutputTokens: 16384,
              pricing: .init(multiplier: multiplier, baseRateVersion: "initial", unit: "credit"),
              modelVersion: 1, capabilities: ["reasoning": false])
    }
}
