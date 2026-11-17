import Foundation

extension RegisteredProvider {
    /// The server includes a compatibility route with the default model's metadata.
    /// Match the full snapshot, never just its label, and retain ambiguous aliases.
    var explicitCloudDefault: RegisteredModel? {
        guard isCloud, let alias = models.first(where: { $0.reference == "cloud:default" }) else { return nil }
        let matches = models.filter { model in
            guard model.id != "default" else { return false }
            var snapshot = model
            snapshot.id = alias.id
            snapshot.reference = alias.reference
            return snapshot == alias
        }
        return matches.count == 1 ? matches.first : nil
    }
}

extension AskModelLibrary {
    /// Use the scenario's catalog for both picker contents and selected-model presentation.
    func presentationProvider(_ provider: RegisteredProvider, scenario: String) -> RegisteredProvider {
        var result = provider
        if provider.isCloud, scenario == "rewrite", let rewriteCloud {
            result.models = rewriteCloud.map(\.registered)
        }
        result.models.sort(by: RegisteredModel.alphabetical)
        return result
    }

    func presentationModel(for reference: String, scenario: String) -> (RegisteredProvider, RegisteredModel)? {
        let displayed = presentationReference(for: reference, scenario: scenario)
        for provider in providers {
            let source = presentationProvider(provider, scenario: scenario)
            if let model = source.models.first(where: { $0.reference == displayed }) {
                return (source, model)
            }
        }
        return nil
    }

    /// Presentation only: saved defaults and conversation routing keep their original references.
    func presentationReference(for reference: String, scenario: String = "ask") -> String {
        guard reference == "cloud:default",
              let model = providers.first(where: \.isCloud).map({ presentationProvider($0, scenario: scenario) })?.explicitCloudDefault else { return reference }
        return model.reference
    }
}
