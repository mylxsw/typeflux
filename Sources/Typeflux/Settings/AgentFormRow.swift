import SwiftUI

/// A label column followed by its control, as used by the search and MCP forms.
struct AgentFormRow<Field: View>: View {
    let label: String
    var required = false
    @ViewBuilder var field: Field

    var body: some View {
        TypefluxSettingsRow(label + (required ? " *" : "")) { field }
            .accessibilityLabel(label + (required ? ", " + L("agent.form.required") : ""))
    }
}
