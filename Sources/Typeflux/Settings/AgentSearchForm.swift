import SwiftUI

/// Provider choice, credentials and connection test for local web search.
struct AgentSearchForm: View {
    @Binding var provider: AskSearchSettings.Provider
    @Binding var apiKey: String
    @Binding var cloudflare: AskCloudflareSearchConfiguration
    let missing: [AgentSearchField]
    let configuration: AskSearchConfiguration
    @StateObject private var connection = AskCloudflareConnectionTest()

    var body: some View {
        Group {
            // Turning search off is the pane's switch, so only real providers are offered here.
            TypefluxSegmentedControl(L("agent.search.section"), selection: $provider) {
                ForEach(AskSearchSettings.Provider.allCases.filter { $0 != .none }, id: \.self) {
                    Text(AgentCapabilityStatus.searchProviderName($0)).tag($0)
                }
            }
            if provider != .none {
                AgentFormRow(label: AgentSearchField.apiKey.title(for: provider), required: true) {
                    SecureField(
                        provider == .cloudflare ? L("agent.search.cloudflare.tokenPlaceholder") :
                            L("agent.search.keyPlaceholder"),
                        text: $apiKey
                    )
                    .textFieldStyle(.roundedBorder)
                }
                if provider == .cloudflare {
                    AskCloudflareSearchSettingsView(configuration: $cloudflare)
                }
                testBar
                footnote
            }
        }
        .onChange(of: provider) { _ in connection.reset() }
        .onChange(of: apiKey) { _ in connection.reset() }
        .onChange(of: cloudflare) { _ in connection.reset() }
        .onDisappear { connection.reset() }
    }

    private var testBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    connection.start(configuration)
                } label: {
                    HStack(spacing: 6) {
                        if connection.testing {
                            ProgressView().controlSize(.small)
                        }
                        Text(L(connection.testing
                                ? "ask.settings.search.cloudflare.testing" : "ask.settings.search.cloudflare.test"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(connection.testing || !missing.isEmpty)
                if !missing.isEmpty {
                    Text(L("agent.search.missing",
                           missing.map { $0.title(for: provider) }.joined(separator: L("agent.listSeparator"))))
                        .font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }
            }
            if let result = connection.result {
                let succeeded = connection.succeeded == true
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(result).fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(succeeded ? TypefluxColor.success.color : TypefluxColor.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if provider == .cloudflare {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("agent.search.cloudflare.help")).fixedSize(horizontal: false, vertical: true)
                Link(L("ask.settings.search.cloudflare.guide"),
                     destination: URL(string: "https://developers.cloudflare.com/web-search/how-to-use/")!)
            }
            .font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color)
        } else if let url = Self.keyURL(for: provider) {
            Link(L("agent.search.getKey", AgentCapabilityStatus.searchProviderName(provider)), destination: url)
                .font(.subheadline)
        }
    }

    static func keyURL(for provider: AskSearchSettings.Provider) -> URL? {
        switch provider {
        case .tavily: URL(string: "https://app.tavily.com/")
        case .brave: URL(string: "https://api-dashboard.search.brave.com/")
        case .none, .cloudflare: nil
        }
    }
}
