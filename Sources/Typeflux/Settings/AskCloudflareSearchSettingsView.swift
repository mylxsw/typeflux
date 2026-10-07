import SwiftUI

/// Cloudflare-specific search fields; the token and connection test live in the surrounding form.
struct AskCloudflareSearchSettingsView: View {
    @Binding var configuration: AskCloudflareSearchConfiguration
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentFormRow(label: L("ask.settings.search.cloudflare.account"), required: true) {
                TextField(L("agent.search.cloudflare.accountPlaceholder"), text: $configuration.accountID)
                    .textFieldStyle(ModelFieldStyle())
            }
            AgentFormRow(label: L("ask.settings.search.cloudflare.gateway"), required: true) {
                TextField("default", text: $configuration.gatewayID).textFieldStyle(ModelFieldStyle())
            }
            AgentFormRow(label: L("ask.settings.search.cloudflare.provider")) {
                SettingsMenuPicker(title: L("ask.settings.search.cloudflare.provider"),
                                   options: AskCloudflareSearchConfiguration.providers.map { (
                                       label: Self.engineName($0),
                                       value: $0
                                   ) },
                                   selection: $configuration.provider)
            }
            AgentDisclosureButton(title: L("agent.search.advanced"), expanded: $showsAdvanced)
            if showsAdvanced || !configuration.byokAlias.isEmpty {
                AgentFormRow(label: L("ask.settings.search.cloudflare.alias")) {
                    TextField(L("agent.search.cloudflare.aliasPlaceholder"), text: $configuration.byokAlias)
                        .textFieldStyle(ModelFieldStyle())
                }
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

/// A label column followed by its control, as used by the search and MCP forms.
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

/// Small chevron toggle that reveals rarely needed fields.
struct AgentDisclosureButton: View {
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }
}
