import SwiftUI

/// Native form sections shared by the Agent and Launcher settings.
struct AgentSettingsSection<Content: View>: View {
    let title: String
    var detail: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        TypefluxFormSection(title + (detail.map { " · " + $0 } ?? ""), footer: footnote) { content }
    }
}
