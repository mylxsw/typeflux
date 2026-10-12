import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        TypefluxForm {
            TypefluxFormSection(AppSettingsPane.advanced.title) {
                TypefluxSettingsRow(L("settings.advanced.voiceProcessingTimeout.title"),
                                    description: L("settings.advanced.voiceProcessingTimeout.subtitle")) {
                    TypefluxPopup(L("settings.advanced.voiceProcessingTimeout.title"), selection: Binding(
                        get: { viewModel.voiceProcessingTimeout }, set: viewModel.setVoiceProcessingTimeout
                    ), borderless: true) {
                        ForEach(VoiceProcessingTimeout.allCases, id: \.self) { timeout in
                            Text(timeout.displayName).tag(timeout)
                        }
                    }
                }
            }
            TypefluxFormSection(L("settings.servers.title")) {
                serverRow("api", servers: viewModel.availableAPIServers, statuses: viewModel.apiServerStatuses,
                          selection: Binding(get: { viewModel.preferredAPIServer },
                                             set: viewModel.setPreferredAPIServer))
                serverRow("asr", servers: viewModel.availableASRServers, statuses: viewModel.asrServerStatuses,
                          selection: Binding(get: { viewModel.preferredASRServer },
                                             set: viewModel.setPreferredASRServer))
                TypefluxSettingsRow(L("settings.servers.speedTest.title"), description: viewModel.cloudServerTestSummary
                    ?? L("settings.servers.speedTest.subtitle")) {
                    TypefluxButton(L(viewModel.isTestingCloudServers
                        ? "settings.servers.speedTest.testing" : "settings.servers.speedTest.action")) {
                        viewModel.testCloudServerLatency()
                    }
                    .disabled(viewModel.isTestingCloudServers)
                }
            }
        }
    }

    private func serverRow(_ kind: String, servers: [String], statuses: [CloudEndpointStatus],
                           selection: Binding<String>) -> some View {
        TypefluxSettingsRow(L("settings.servers." + kind + ".title"),
                            description: L("settings.servers." + kind + ".subtitle")) {
            TypefluxPopup(L("settings.servers." + kind + ".title"), selection: selection, borderless: true) {
                Text(L("settings.servers.automatic")).tag(CloudServerPreferences.automaticValue)
                ForEach(servers, id: \.self) { server in
                    Text(serverLabel(server, statuses: statuses)).tag(server)
                }
            }
        }
    }

    func serverLabel(_ server: String, statuses: [CloudEndpointStatus]) -> String {
        let domain = URL(string: server)?.host ?? server
        let status = statuses.first { $0.baseURL.absoluteString == server }
        let tag: String
        if status?.lastError != nil {
            tag = L("settings.servers.tag.unavailable")
        } else if let latency = status?.latencyMs {
            let key = latency < 150 ? "fast" : latency < 350 ? "average" : "slow"
            tag = L("settings.servers.tag." + key, Int(latency.rounded()))
        } else {
            tag = L("settings.servers.tag.notTested")
        }
        return domain + " · " + tag
    }
}
