import Foundation
import Testing
@testable import Typeflux

@Suite("Cloud catalog synchronization", .serialized, .exclusiveUIState)
@MainActor
struct CloudCatalogSyncTests {
    @Test func settingsHideOnlyTheCloudRoutingAliasWithoutChangingRegistry() throws {
        let models: [RegisteredModel] = [
            .init(id: "default", name: "System default", reference: "cloud:default"),
            .init(id: "123e4567-e89b-12d3-a456-426614174000", name: "Published", reference: "cloud:published"),
        ]
        let cloud = RegisteredProvider(id: "typefluxCloud", name: "Cloud", remote: .typefluxCloud, models: models)
        #expect(cloud.configurationModels.map(\.name) == ["Published"])
        #expect(cloud.models.count == 2)
        let registry = ModelRegistry(providers: [cloud])
        #expect(registry.resolve("cloud:default") != nil)
        let custom = RegisteredProvider(id: "custom", name: "Custom", models: models)
        #expect(custom.configurationModels.count == 2)
    }

    @Test func publishedModelsReplaceCachePreserveSelectionAndReflectRemoval() async throws {
        let suite = "cloud-sync-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        let api = AskTestAPI()
        let published = AskCloudModel(id: "published", name: "Published", vision: true, scenarios: ["ask"],
                                      contextWindowTokens: 204800, maxOutputTokens: 16384,
                                      pricing: .init(multiplier: "2"), modelVersion: 1, capabilities: ["reasoning": true])
        let customBefore = library.providers.filter { !$0.isCloud }
        library.defaultReference = published.reference
        await api.setCloudModels([published])
        await library.refresh(api: api, token: "fixture")
        #expect(library.providers.first(where: \.isCloud)?.models == [published.registered])
        #expect(library.defaultReference == published.reference)
        #expect(library.providers.filter { !$0.isCloud } == customBefore)
        #expect(library.registry.resolve(published.reference)?.1.contextWindowTokens == 204800)
        let restored = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        #expect(restored.registry.resolve(published.reference)?.1 == published.registered)
        #expect(restored.selectableProviders(loggedIn: true, hasImage: true).first(where: \.isCloud)?.models == [published.registered])
        await api.setFailModels(true)
        await library.refresh(api: api, token: "fixture")
        #expect(library.catalogError != nil)
        #expect(library.registry.resolve(published.reference) != nil)
        await api.setFailModels(false)
        await api.setCloudModels([])
        await library.refresh(api: api, token: "fixture")
        #expect(library.catalogError == nil)
        #expect(library.providers.first(where: \.isCloud)?.models.isEmpty == true)
        #expect(library.defaultReference == published.reference)
        #expect(library.registry.resolve("cloud:default") == nil)
    }

    @Test func refreshRestoresMissingCloudProviderWithoutManualImport() async throws {
        let suite = "cloud-restore-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        var registry = library.registry
        registry.providers.removeAll(where: \.isCloud)
        try library.commit(registry)
        await library.refresh(api: AskTestAPI(), token: nil)
        #expect(library.providers.first(where: \.isCloud) == nil)
        await library.refresh(api: AskTestAPI(), token: "fixture")
        #expect(library.providers.first(where: \.isCloud)?.models.map(\.id) == ["default"])
    }
}
