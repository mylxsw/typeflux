import SwiftUI

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
                    TextField(keyPlaceholder, text: $row.key).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L("agent.mcp.kv.key"))
                        .frame(maxWidth: 170)
                    Group {
                        if row.isSecret {
                            SecureField(valuePlaceholder, text: $row.value)
                        } else {
                            TextField(valuePlaceholder, text: $row.value)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(valuePlaceholder)
                    TypefluxIconButton(L("ask.remove"), systemImage: "minus") {
                        rows.removeAll { $0.id == row.id }
                        if rows.isEmpty {
                            rows = [MCPKeyValueRow()]
                        }
                    }
                }
            }
            Button {
                rows.append(MCPKeyValueRow())
            } label: {
                Label(L("agent.mcp.kv.add"), systemImage: "plus").font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TypefluxColor.accent.color)
        }
        .onAppear {
            // Rows own the editing state so an empty key being typed is not dropped by a round trip.
            guard !loaded else { return }
            loaded = true
            rows = MCPKeyValueRow.rows(from: text)
            if rows.isEmpty {
                rows = [MCPKeyValueRow()]
            }
        }
        .onChange(of: rows) { text = MCPKeyValueRow.text(from: $0) }
    }
}
