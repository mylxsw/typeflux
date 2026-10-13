import SwiftUI

struct AgentSettingsActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: icon) }.buttonStyle(.borderless)
    }
}
