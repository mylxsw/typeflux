import SwiftUI

/// Grouped list of panes; each row shows the pane's state as a dot.
struct SettingsPaneList<Pane: SettingsPaneItem>: View {
    let sections: [(title: String?, panes: [Pane])]
    @Binding var selection: Pane
    var status: (Pane) -> AgentCapabilityStatus? = { _ in nil }

    var body: some View {
        List(selection: Binding<Pane?>(get: { selection }, set: {
            if let pane = $0 {
                selection = pane
            }
        })) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.panes) { pane in
                        HStack {
                            Label(pane.title, systemImage: pane.symbol).font(.body)
                            Spacer(minLength: 4)
                            if let state = status(pane) {
                                AgentStatusDot(level: state.level)
                            }
                        }
                        .tag(pane)
                        .accessibilityIdentifier("settings.pane.\(pane.id)")
                        .accessibilityLabel(status(pane).map { "\(pane.title), \($0.label)" } ?? pane.title)
                    }
                } header: {
                    if let title = section.title {
                        Text(title).font(.subheadline)
                    }
                }
            }
        }.listStyle(.sidebar)
    }
}
