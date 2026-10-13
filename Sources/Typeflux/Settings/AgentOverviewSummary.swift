import SwiftUI

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
            : L("agent.overview.needsAttention", attention.count,
                attention.map(\.capability.title).joined(separator: L("agent.listSeparator")))]
        if noteCount > 0 {
            parts.append(L("agent.overview.notes", noteCount))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        TypefluxSettingsRow(L("agent.overview.ready", statuses.filter { $0.level == .ready }.count),
                            description: detail) {
            if let first = attention.first {
                Button(L("agent.overview.fix")) { onFix(first) }.buttonStyle(.borderedProminent)
            }
        }
    }
}
