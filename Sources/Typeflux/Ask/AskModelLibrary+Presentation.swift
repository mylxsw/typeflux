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
    /// Presentation only: saved defaults and conversation routing keep their original references.
    func presentationReference(for reference: String, scenario: String = "ask") -> String {
        guard scenario == "ask", reference == "cloud:default",
              let model = providers.first(where: \.isCloud)?.explicitCloudDefault else { return reference }
        return model.reference
    }
}
