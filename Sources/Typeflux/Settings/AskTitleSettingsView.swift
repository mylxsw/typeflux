import SwiftUI

struct AskTitleSettingsView: View {
    let settings: SettingsStore
    @ObservedObject private var library = AskModelLibrary.shared
    @ObservedObject private var auth = AuthState.shared
    @State private var enabled = true
    @State private var reference = ""
    @State private var cloudModels: [AskCloudModel] = []

    private var options: [(label: String, value: String)] {
        var values = [(label: L("ask.title.auto"), value: "")]
        values += cloudModels.filter { $0.id != "default" }.map { (label: "Typeflux Cloud · " + $0.name,
                                                                   value: $0.registered.reference) }
        for provider in library.selectableProviders(loggedIn: false, hasImage: false, scenario: "rewrite") {
            values += provider.models.map { (label: provider.name + " · " + $0.displayName, value: $0.reference) }
        }
        if !reference.isEmpty, !values.contains(where: { $0.value == reference }) {
            values.append((label: L("ask.models.unavailable"), value: reference))
        }
        return values
    }

    var body: some View {
        AgentSettingsSection(title: L("ask.title.section")) {
            AgentSettingsRow(icon: "textformat", title: L("ask.title.enabled"),
                             subtitle: L("ask.title.enabled.subtitle")) {
                Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(L("ask.title.enabled"))
            }
            AgentSettingsRow(
                icon: "sparkles",
                title: L("ask.title.model"),
                subtitle: L("ask.title.model.subtitle"),
                subtitleLineLimit: nil
            ) {
                TypefluxPopup(title: L("ask.title.model"), options: options, selection: $reference)
                    .frame(width: 200).disabled(!enabled)
            }
            Text(L("ask.title.cost")).font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { enabled = settings.askAutomaticTitles; reference = settings.askTitleModelReference }
        .onChange(of: enabled) { settings.askAutomaticTitles = $0 }
        .onChange(of: reference) { settings.askTitleModelReference = $0 }
        .task(id: auth.isLoggedIn) {
            cloudModels = []
            guard auth.isLoggedIn, let token = auth.accessToken else { return }
            cloudModels = await (try? AskAPIClient().featureModels(feature: "conversation-title", token: token)) ?? []
        }
    }
}
