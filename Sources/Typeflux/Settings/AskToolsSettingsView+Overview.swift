import SwiftUI

/// The Overview pane: what Ask can use now, what needs fixing, and where new conversations are kept.
extension AskToolsSettingsView {
    @ViewBuilder var overviewSections: some View {
        FeatureTriggerSettingsView(settings: settings, feature: .chat)
        let statuses = capabilityStatuses
        AgentOverviewSummary(statuses: statuses, noteCount: memoryNotes.notes.count) { status in
            navigate(to: status.capability)
        }
        TFFormSection {
            TFFormRow(title: L("ask.settings.local.title"), icon: "archivebox") {
                TFPopUpButton(title: L("ask.settings.local.title"),
                              options: [TFOption(false, Self.storageName(local: false), systemImage: "cloud"),
                                        TFOption(true, Self.storageName(local: true), systemImage: "lock")],
                              selection: Binding(get: { newConversationsStayLocal }, set: setNewConversationsStayLocal),
                              width: TFMetrics.formControlWidth, identifier: "agent.settings.newConversationStorage")
            }
        }
        AskAgentStepSettingsView(settings: settings)
        AskTitleSettingsView(settings: settings)
        AskTemporarySettingsView(settings: settings)
        let attention = statuses.filter { $0.level == .attention }
        TFFormSection(title: L("agent.overview.attention.title"), count: attention.isEmpty ? nil : attention.count) {
            if attention.isEmpty {
                TFCardNote(text: L("agent.overview.attention.none"))
            }
            ForEach(Array(attention.enumerated()), id: \.element.id) { index, status in
                if index > 0 { TFDivider.formWithIcon }
                TFFormRow(title: status.capability.title, valueText: status.label, icon: status.capability.symbol) {
                    TFButton(title: L("agent.overview.attention.action"), systemImage: "chevron.right") {
                        navigate(to: status.capability)
                    }
                }
            }
        }
    }

    func navigate(to capability: AgentCapability) {
        onNavigate(capability.pane)
    }
}

/// Headline count of usable capabilities and a shortcut to the first one needing attention.
struct AgentOverviewSummary: View {
    let statuses: [AgentCapabilityStatus]
    let noteCount: Int
    let onFix: (AgentCapabilityStatus) -> Void

    private var attention: [AgentCapabilityStatus] {
        statuses.filter { $0.level == .attention }
    }

    var detail: String {
        var parts = [attention.isEmpty
            ? L("agent.overview.allSet")
            : L("agent.overview.needsAttention", attention.count, attention.map(\.capability.title).joined(separator: L("agent.listSeparator")))]
        if noteCount > 0 { parts.append(L("agent.overview.notes", noteCount)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        TFCard {
            TFFormRow(title: L("agent.overview.ready", statuses.filter { $0.level == .ready }.count),
                      valueText: detail, icon: attention.isEmpty ? "checkmark.seal" : "exclamationmark.circle") {
                if let first = attention.first {
                    TFButton(title: L("agent.overview.fix"), kind: .primary) { onFix(first) }
                }
            }
        }
    }
}
