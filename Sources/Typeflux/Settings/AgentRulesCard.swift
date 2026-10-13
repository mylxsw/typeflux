import SwiftUI

struct AgentRulesCard: View {
    var title = L("agent.rules.title")
    let rules: [(title: String, detail: String?)]
    var dimmed = false

    var body: some View {
        AgentSettingsSection(title: title) {
            ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                TypefluxSettingsRow(rule.title, description: rule.detail) {
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary).accessibilityHidden(true)
                }
            }
        }.opacity(dimmed ? 0.5 : 1)
    }
}
