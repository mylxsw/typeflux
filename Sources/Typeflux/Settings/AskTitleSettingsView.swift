import SwiftUI

/// Settings → Agent → Overview: automatic conversation titles and the model that writes them.
struct AskTitleSettingsView: View {
    let settings: SettingsStore
    @ObservedObject private var library = AskModelLibrary.shared
    @ObservedObject private var auth = AuthState.shared
    @State private var enabled = true
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
        TFFormSection(title: L("ask.title.section")) {
            TFFormRow(title: L("ask.title.enabled"), detail: L("ask.title.enabled.subtitle"), icon: "pencil.line") {
                TFSwitch(title: L("ask.title.enabled"), isOn: $enabled)
            }
            TFDivider.formWithIcon
            TFFormRow(title: L("ask.title.model"), detail: L("ask.title.model.subtitle"), icon: "sparkles") {
                TFPopUpButton(title: L("ask.title.model"), options: options.map { TFOption($0.value, $0.label) },
                              selection: $reference, width: TFMetrics.formControlWidth)
            }
        }
        .onAppear { enabled = settings.askAutomaticTitles; reference = settings.askAuxiliaryModelReference }
        .onChange(of: enabled) { settings.askAutomaticTitles = $0 }
        .onChange(of: reference) { settings.askAuxiliaryModelReference = $0 }
        .task(id: auth.isLoggedIn) {
            cloudModels = []
            guard let token = auth.accessToken else { return }
            cloudModels = (try? await AskAPIClient().featureModels(feature: "conversation-title", token: token)) ?? []
        }
    }
}
