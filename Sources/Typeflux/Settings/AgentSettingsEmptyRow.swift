import SwiftUI

struct AgentSettingsEmptyRow: View {
    let text: String

    var body: some View {
        Text(text).font(.body).foregroundStyle(.secondary)
    }
}
