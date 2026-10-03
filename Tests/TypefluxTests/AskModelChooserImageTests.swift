import Foundation
import Testing
@testable import Typeflux

@Suite("Ask model chooser with images")
@MainActor
struct AskModelChooserImageTests {
    private func library() throws -> AskModelLibrary {
        let defaults = try #require(UserDefaults(suiteName: "ask-chooser-image-" + UUID().uuidString))
        let library = AskModelLibrary(defaults: defaults, automaticallyLoadsCatalog: false)
        try library.addModels([
            RegisteredModel(id: "sees", name: "Sees", reference: "cloud:sees", vision: true, scenarios: ["ask"]),
            RegisteredModel(id: "blind", name: "Blind", reference: "cloud:blind", vision: false, scenarios: ["ask"]),
            RegisteredModel(id: "unknown", name: "Unknown", reference: "cloud:unknown", scenarios: ["ask"])
        ], providerID: "typefluxCloud")
        return library
    }

    @Test func modelsThatCannotReadImagesAreListedWithAReason() throws {
        let library = try library()
        let all = library.selectableProviders(loggedIn: true, hasImage: false)
        let cloud = try #require(all.first { $0.isCloud })
        let reasons = Dictionary(uniqueKeysWithValues: cloud.models.map { model in
            (model.id, AskModelChoices.imageReason(model, provider: cloud, hasImage: true, library: library,
                                                   loggedIn: true, scenario: "ask"))
        })
        #expect(reasons["sees"] == .some(nil))
        #expect(reasons["blind"] == .some(L("models.noVision")))
        #expect(reasons["unknown"] == .some(L("models.unknownVision")))
        // The image-capable list still excludes them, so they cannot be picked.
        let compatible = library.selectableProviders(loggedIn: true, hasImage: true)
        #expect(compatible.first { $0.isCloud }?.models.map(\.id).filter { ["sees", "blind", "unknown"].contains($0) } == ["sees"])
    }

    @Test func withoutImagesNothingIsBlocked() throws {
        let library = try library()
        let cloud = try #require(library.selectableProviders(loggedIn: true, hasImage: false).first { $0.isCloud })
        for model in cloud.models {
            #expect(AskModelChoices.imageReason(model, provider: cloud, hasImage: false, library: library,
                                                loggedIn: true, scenario: "ask") == nil)
        }
    }

    @Test func ownModelsOfUnknownVisionCanBeTriedWithImages() throws {
        let library = try library()
        // Only these models on Ollama, without the migrated default.
        var registry = library.registry
        if let index = registry.providers.firstIndex(where: { $0.isOllama }) { registry.providers[index].models = [] }
        try library.commit(registry)
        try library.addModels([
            RegisteredModel(id: "house-model", name: "House", reference: "custom:house"),
            RegisteredModel(id: "gpt-4o", name: "GPT-4o", reference: "custom:guessed"),
            RegisteredModel(id: "deepseek-chat", name: "DeepSeek", reference: "custom:text")
        ], providerID: "ollama")
        library.ollamaAvailable = true
        let ollama = try #require(library.providers.first { $0.isOllama })
        let byReference = Dictionary(uniqueKeysWithValues: ollama.models.map { ($0.reference, $0) })
        let house = try #require(byReference["custom:house"])
        #expect(AskModelChoices.imageReason(house, provider: ollama, hasImage: true, library: library,
                                            loggedIn: true, scenario: "ask") == nil)
        #expect(AskModelChoices.imageTrialCaption(house, provider: ollama, hasImage: true) == L("ask.models.visionTrial"))
        #expect(AskModelChoices.imageTrialCaption(house, provider: ollama, hasImage: false) == nil)
        let guessed = try #require(byReference["custom:guessed"])
        #expect(AskModelChoices.imageTrialCaption(guessed, provider: ollama, hasImage: true) == nil)
        #expect(AskModelCapabilities.badges(guessed).map(\.text) == [L("ask.models.badge.vision")])
        let text = try #require(byReference["custom:text"])
        #expect(AskModelChoices.imageReason(text, provider: ollama, hasImage: true, library: library,
                                            loggedIn: true, scenario: "ask") == L("models.noVision"))

        let lenient = library.selectableProviders(loggedIn: true, hasImage: true).flatMap(\.models).map(\.reference)
        #expect(lenient.contains("custom:house") && lenient.contains("custom:guessed") && !lenient.contains("custom:text"))
        let strict = library.selectableProviders(loggedIn: true, hasImage: true, confirmedVision: true)
            .flatMap(\.models).map(\.reference)
        #expect(!strict.contains("custom:house") && strict.contains("custom:guessed"))
        // Cloud models follow the catalog and are never tried blind.
        let cloud = try #require(library.providers.first { $0.isCloud })
        let cloudUnknown = try #require(cloud.models.first { $0.id == "unknown" })
        #expect(!AskModelLibrary.acceptsImages(cloudUnknown, provider: cloud, confirmedOnly: false))
        #expect(AskModelChoices.imageTrialCaption(cloudUnknown, provider: cloud, hasImage: true) == nil)
        // A local fallback prefers a confirmed vision model.
        #expect(library.firstLocalReference(hasImage: true) == "custom:guessed")
    }
}
