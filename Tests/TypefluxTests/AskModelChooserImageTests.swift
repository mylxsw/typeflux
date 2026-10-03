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
}
