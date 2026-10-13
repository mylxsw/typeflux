import SwiftUI

extension AskToolsSettingsView {
    @ViewBuilder var overviewSections: some View {
        let statuses = capabilityStatuses
        Section {
            AgentOverviewSummary(statuses: statuses, noteCount: memoryNotes.notes.count) { status in
                navigate(to: status.capability)
            }
        }
        TypefluxFormSection(L("ask.settings.local.title"), footer: L("agent.overview.storage.hint")) {
            TypefluxSettingsRow(L("ask.settings.local.title")) {
                TypefluxSegmentedControl(L("ask.settings.local.title"), selection: Binding(
                    get: { newConversationsStayLocal }, set: setNewConversationsStayLocal
                )) {
                    Text(Self.storageName(local: false)).tag(false)
                    Text(Self.storageName(local: true)).tag(true)
                }
            }
            ForEach(storagePoints, id: \.self) { Text(L($0)).font(.subheadline).foregroundStyle(.secondary) }
        }
        AskTitleSettingsView(settings: settings)
        let attention = statuses.filter { $0.level == .attention }
        AgentSettingsSection(title: L("agent.overview.attention.title"),
                             detail: attention.isEmpty ? nil : L("agent.overview.attention.count", attention.count)) {
            if attention.isEmpty {
                AgentSettingsEmptyRow(text: L("agent.overview.attention.none"))
            }
            ForEach(attention) { status in
                AgentSettingsRow(icon: status.capability.symbol, title: status.capability.title,
                                 subtitle: status.label) {
                    Button { navigate(to: status.capability) } label: {
                        Label(L("agent.overview.attention.action"), systemImage: "chevron.right")
                    }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var storagePoints: [String] {
        newConversationsStayLocal
            ? ["agent.storage.local.private", "agent.storage.local.models", "agent.storage.local.search",
               "agent.storage.local.limits"]
            : ["agent.storage.cloud.models", "agent.storage.cloud.sync", "agent.storage.cloud.search",
               "agent.storage.cloud.credits"]
    }

    func navigate(to capability: AgentCapability) {
        onNavigate(capability.pane)
    }
}
