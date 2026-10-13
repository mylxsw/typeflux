import SwiftUI

/// The pane list as a menu, for narrow windows.
struct SettingsPaneMenu<Pane: SettingsPaneItem>: View {
    let sections: [(title: String?, panes: [Pane])]
    @Binding var selection: Pane
    var status: (Pane) -> AgentCapabilityStatus? = { _ in nil }

    var body: some View {
        TypefluxPopup(selection.title, selection: $selection, borderless: true) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.panes) { pane in
                        Label(status(pane).map { "\(pane.title) · \($0.label)" } ?? pane.title,
                              systemImage: pane.symbol)
                            .tag(pane)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }.fixedSize()
    }
}
