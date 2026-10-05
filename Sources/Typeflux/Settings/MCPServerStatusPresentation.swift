import SwiftUI

/// How a saved MCP server's row describes its state: off, untested, connecting, connected or failing.
struct MCPServerStatusPresentation: Equatable {
    enum State: Equatable { case disabled, untested, testing, connected, failed }

    let state: State
    let label: String

    init(enabled: Bool, result: MCPConnectionTestState?) {
        switch (enabled, result) {
        case (false, _):
            (state, label) = (.disabled, L("agent.mcp.status.disabled"))
        case (true, .testing?):
            (state, label) = (.testing, L("agent.mcp.testing"))
        case let (true, .success(tools)?):
            (state, label) = (.connected, L("agent.mcp.status.connected", tools.count))
        case (true, .failure?):
            (state, label) = (.failed, L("agent.mcp.status.failed"))
        case (true, .idle?), (true, nil):
            (state, label) = (.untested, L("agent.mcp.status.untested"))
        }
    }

    var isTesting: Bool {
        state == .testing
    }

    var color: Color {
        switch state {
        case .connected: StudioTheme.success
        case .failed: StudioTheme.danger
        case .testing: StudioTheme.warning
        case .disabled, .untested: StudioTheme.textTertiary
        }
    }
}

/// Edits `KEY=VALUE` lines as rows; secret-looking values are masked.
struct MCPKeyValueEditor: View {
    @Binding var text: String
    let keyPlaceholder: String
    let valuePlaceholder: String
    @State private var rows: [MCPKeyValueRow] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField(keyPlaceholder, text: $row.key).textFieldStyle(ModelFieldStyle())
                        .frame(width: 170)
                    Group {
                        if row.isSecret {
                            SecureField(valuePlaceholder, text: $row.value)
                        } else {
                            TextField(valuePlaceholder, text: $row.value)
                        }
                    }
                    .textFieldStyle(ModelFieldStyle())
                    AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) {
                        rows.removeAll { $0.id == row.id }
                        if rows.isEmpty { rows = [MCPKeyValueRow()] }
                    }
                }
            }
            Button {
                rows.append(MCPKeyValueRow())
            } label: {
                Label(L("agent.mcp.kv.add"), systemImage: "plus").font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ModelVisualStyle.accent)
        }
        .onAppear {
            // Rows own the editing state so an empty key being typed is not dropped by a round trip.
            guard !loaded else { return }
            loaded = true
            rows = MCPKeyValueRow.rows(from: text)
            if rows.isEmpty { rows = [MCPKeyValueRow()] }
        }
        .onChange(of: rows) { text = MCPKeyValueRow.text(from: $0) }
    }
}
