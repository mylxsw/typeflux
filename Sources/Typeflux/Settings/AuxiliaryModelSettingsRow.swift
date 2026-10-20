import SwiftUI

/// Shared helper-model selection lives alongside the other model roles.
struct AuxiliaryModelSettingsRow: View {
    @ObservedObject var library: AskModelLibrary
    @ObservedObject private var auth = AuthState.shared
    @State private var reference = ""
    @State private var cloudModels: [AskCloudModel] = []

    private var options: [(label: String, value: String)] {
        var values = [(label: L("ask.title.auto"), value: "")]
        values += cloudModels.filter { $0.id != "default" }.map { (label: "Typeflux Cloud · " + $0.name, value: $0.registered.reference) }
        for provider in library.selectableProviders(loggedIn: false, hasImage: false, scenario: "rewrite") {
            values += provider.models.map { (label: provider.name + " · " + $0.displayName, value: $0.reference) }
        }
        if !reference.isEmpty, !values.contains(where: { $0.value == reference }) {
            values.append((label: L("ask.models.unavailable"), value: reference))
        }
        return values
    }

    var body: some View {
        TFFormRow(title: L("ask.title.model"), detail: L("ask.title.model.subtitle"), icon: "sparkles") {
            TFPopUpButton(title: L("ask.title.model"), options: options.map { TFOption($0.value, $0.label) },
                          selection: $reference, width: 240,
                          identifier: "models.scene.auxiliary")
        }
        .onAppear { reference = library.settings.askAuxiliaryModelReference }
        .onChange(of: reference) { library.settings.askAuxiliaryModelReference = $0 }
        .task(id: auth.accessToken) {
            cloudModels = []
            guard library.automaticallyLoadsCatalog, let token = auth.accessToken else { return }
            cloudModels = (try? await AskAPIClient().featureModels(feature: "conversation-title", token: token)) ?? []
        }
    }
}
