import SwiftUI

/// The window owns the title. Capability state and actions are ordinary form rows.
struct AgentPaneHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Group {
            if Accessory.self != EmptyView.self {
                Section {
                    AgentSettingsRow(icon: symbol, title: title, subtitle: subtitle) { accessory }
                }
            }
        }.navigationTitle(title)
    }
}

extension AgentPaneHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}
