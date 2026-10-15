import SwiftUI

/// Cloudflare-specific search rows; the token and connection test live in the surrounding form.
struct AskCloudflareSearchSettingsView: View {
    @Binding var configuration: AskCloudflareSearchConfiguration
    @State private var showsAdvanced = false

    var body: some View {
        TFDivider.formWithIcon
        TFFormRow(title: L("ask.settings.search.cloudflare.account"), icon: "person.crop.square", isRequired: true,
                  controlWidth: .wide) {
            TextField(L("agent.search.cloudflare.accountPlaceholder"), text: $configuration.accountID)
                .textFieldStyle(TFTextFieldStyle(monospaced: true))
        }
        TFDivider.formWithIcon
        TFFormRow(title: L("ask.settings.search.cloudflare.gateway"), icon: "point.3.connected.trianglepath.dotted",
                  isRequired: true, controlWidth: .wide) {
            TextField("default", text: $configuration.gatewayID).textFieldStyle(TFTextFieldStyle(monospaced: true))
        }
        TFDivider.formWithIcon
        TFFormRow(title: L("ask.settings.search.cloudflare.provider"), icon: "magnifyingglass",
                  controlWidth: .wide) {
            TFPopUpButton(title: L("ask.settings.search.cloudflare.provider"),
                          options: AskCloudflareSearchConfiguration.providers.map { TFOption($0, Self.engineName($0)) },
                          selection: $configuration.provider, width: TFMetrics.formControlWideWidth)
        }
        TFDivider.form
        TFDisclosureRow(title: L("agent.search.advanced"), isExpanded: $showsAdvanced)
        if showsAdvanced || !configuration.byokAlias.isEmpty {
            TFFormRow(title: L("ask.settings.search.cloudflare.alias"), icon: "key.horizontal", controlWidth: .wide) {
                TextField(L("agent.search.cloudflare.aliasPlaceholder"), text: $configuration.byokAlias)
                    .textFieldStyle(TFTextFieldStyle(monospaced: true))
            }
        }
    }

    static func engineName(_ provider: String) -> String {
        switch provider {
        case "ceramic": "Ceramic.ai"
        case "exa": "Exa"
        default: "Linkup"
        }
    }
}

/// A label column followed by its control, as used by the MCP and translation-provider sheets.
struct AgentFormRow<Field: View>: View {
    let label: String
    var required = false
    var labelWidth: CGFloat = 150
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                if required {
                    Text("*").font(.system(size: 12.5)).foregroundStyle(StudioTheme.danger)
                        .accessibilityLabel(L("agent.form.required"))
                }
            }
            .frame(width: labelWidth, alignment: .leading)
            field.frame(maxWidth: 420, alignment: .leading)
        }
    }
}
