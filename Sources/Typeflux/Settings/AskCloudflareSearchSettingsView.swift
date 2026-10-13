import SwiftUI

/// Cloudflare-specific search fields; the token and connection test live in the surrounding form.
struct AskCloudflareSearchSettingsView: View {
    @Binding var configuration: AskCloudflareSearchConfiguration
    @State private var showsAdvanced = false

    var body: some View {
        Group {
            AgentFormRow(label: L("ask.settings.search.cloudflare.account"), required: true) {
                TextField(L("agent.search.cloudflare.accountPlaceholder"), text: $configuration.accountID)
                    .textFieldStyle(.roundedBorder)
            }
            AgentFormRow(label: L("ask.settings.search.cloudflare.gateway"), required: true) {
                TextField("default", text: $configuration.gatewayID).textFieldStyle(.roundedBorder)
            }
            AgentFormRow(label: L("ask.settings.search.cloudflare.provider")) {
                TypefluxPopup(title: L("ask.settings.search.cloudflare.provider"),
                              options: AskCloudflareSearchConfiguration.providers.map { (
                                  label: Self.engineName($0),
                                  value: $0
                              ) },
                              selection: $configuration.provider)
            }
            DisclosureGroup(L("agent.search.advanced"), isExpanded: $showsAdvanced) {
                AgentFormRow(label: L("ask.settings.search.cloudflare.alias")) {
                    TextField(L("agent.search.cloudflare.aliasPlaceholder"), text: $configuration.byokAlias)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .onAppear { showsAdvanced = !configuration.byokAlias.isEmpty }
    }

    static func engineName(_ provider: String) -> String {
        switch provider {
        case "ceramic": "Ceramic.ai"
        case "exa": "Exa"
        default: "Linkup"
        }
    }
}
