import SwiftUI

struct AskCloudflareSearchSettingsView: View {
    @Binding var configuration: AskCloudflareSearchConfiguration
    let apiKey: String
    @StateObject private var connection = AskCloudflareConnectionTest()

    private var searchConfiguration: AskSearchConfiguration {
        .init(provider: .cloudflare, apiKey: apiKey, cloudflare: configuration)
    }

    var body: some View {
        Group {
            field("ask.settings.search.cloudflare.account", text: $configuration.accountID)
            field("ask.settings.search.cloudflare.gateway", text: $configuration.gatewayID)
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "magnifyingglass", title: L("ask.settings.search.cloudflare.provider")) {
                Picker(L("ask.settings.search.cloudflare.provider"), selection: $configuration.provider) {
                    ForEach(AskCloudflareSearchConfiguration.providers, id: \.self) { provider in
                        Text(provider == "ceramic" ? "Ceramic.ai" : provider == "exa" ? "Exa" : "Linkup").tag(provider)
                    }
                }.labelsHidden().frame(width: 240)
            }
            field("ask.settings.search.cloudflare.alias", text: $configuration.byokAlias)
            Text(L("ask.settings.search.cloudflare.help"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
            HStack {
                Link(L("ask.settings.search.cloudflare.guide"), destination: URL(string: "https://developers.cloudflare.com/web-search/how-to-use/")!)
                Spacer()
                Button(L(connection.testing
                         ? "ask.settings.search.cloudflare.testing" : "ask.settings.search.cloudflare.test")) {
                    connection.start(searchConfiguration)
                }
                    .disabled(connection.testing || !searchConfiguration.isConfigured)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            if let testResult = connection.result {
                Text(testResult).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .onChange(of: configuration) { _ in connection.reset() }
        .onChange(of: apiKey) { _ in connection.reset() }
        .onDisappear { connection.reset() }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        Group {
            ModelRowDivider(leading: 66)
            AgentSettingsRow(icon: "globe", title: L(title)) {
                TextField(L(title), text: text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).frame(width: 240)
            }
        }
    }
}
