import SwiftUI

/// MCP connection form with the same fields, cards and actions as model endpoint settings.
struct MCPServerEditorView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onClose: () -> Void

    var body: some View {
        TypefluxSheet(title: L(viewModel.mcpDraftEditingServerID == nil
                          ? "agent.mcp.dialog.addTitle" : "agent.mcp.dialog.editTitle"),
        cancelTitle: L("common.cancel"), confirmTitle: L("common.save"),
        isConfirmEnabled: viewModel.canSaveMCPDraft,
        cancel: closeEditor, confirm: { viewModel.saveMCPDraft(); closeEditor() }, content: {
            TypefluxForm {
                Section { connectionCard }
                Section {
                    settingRow("agent.mcp.enabled.title", subtitle: "agent.mcp.enabled.subtitle",
                               selection: $viewModel.mcpDraftEnabled)
                    settingRow("agent.mcp.autoConnect.title", subtitle: "agent.mcp.autoConnect.subtitle",
                               selection: $viewModel.mcpDraftAutoConnect)
                }
                Section {
                    Button(L(viewModel
                            .mcpConnectionTestState == .testing ? "agent.mcp.testing" : "agent.mcp.testConnection")) {
                        viewModel.testMCPDraftConnection()
                    }.disabled(!viewModel.canSaveMCPDraft || viewModel.mcpConnectionTestState == .testing)
                    mcpConnectionTestResultView
                }
            }.frame(height: min(500, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 240)))
        }).frame(width: 560)
            .onDisappear { viewModel.resetMCPDraftConnectionTest() }
    }

    @ViewBuilder
    private var connectionCard: some View {
        formRow("agent.mcp.name") {
            TextField(L("agent.mcp.namePlaceholder"), text: $viewModel.mcpDraftName)
                .textFieldStyle(.roundedBorder)
        }
        formRow("agent.mcp.transportType") {
            TypefluxPopup(title: L("agent.mcp.transportType"),
                          options: [(label: L("agent.mcp.transport.stdio"), value: MCPTransportType.stdio),
                                    (label: L("agent.mcp.transport.http"), value: MCPTransportType.http)],
                          selection: $viewModel.mcpDraftTransportType)
        }
        if viewModel.mcpDraftTransportType == .stdio {
            formRow("agent.mcp.stdio.command") {
                TextField("/usr/local/bin/my-mcp-server", text: $viewModel.mcpDraftStdioCommand)
                    .textFieldStyle(.roundedBorder)
            }
            formRow("agent.mcp.stdio.args") {
                TextField("--port 3000 --verbose", text: $viewModel.mcpDraftStdioArgs)
                    .textFieldStyle(.roundedBorder)
            }
            keyValueEditor(
                label: "agent.mcp.stdio.env",
                placeholder: "NODE_ENV",
                text: $viewModel.mcpDraftStdioEnv
            )
            .id(MCPTransportType.stdio)
        } else {
            formRow("agent.mcp.http.url") {
                TextField("https://mcp.example.com/sse", text: $viewModel.mcpDraftHTTPURL)
                    .textFieldStyle(.roundedBorder)
            }
            keyValueEditor(
                label: "agent.mcp.http.headers",
                placeholder: "Authorization",
                text: $viewModel.mcpDraftHTTPHeaders
            )
            .id(MCPTransportType.http)
        }
    }

    private func formRow(_ key: String, @ViewBuilder field: () -> some View) -> some View {
        AgentFormRow(label: L(key), field: field)
    }

    private func keyValueEditor(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(label)).font(.body).foregroundStyle(.secondary)
            MCPKeyValueEditor(text: text, keyPlaceholder: placeholder, valuePlaceholder: L("agent.mcp.kv.value"))
        }
    }

    private func settingRow(_ title: String, subtitle: String, selection: Binding<Bool>) -> some View {
        TypefluxSettingsRow(L(title), description: L(subtitle)) {
            TypefluxSwitch(L(title), isOn: selection, labelsHidden: true)
        }
    }

    private func closeEditor() {
        // A sheet's disappearance can be delayed by its dismissal animation.
        viewModel.resetMCPDraftConnectionTest()
        onClose()
    }

    @ViewBuilder private var mcpConnectionTestResultView: some View {
        switch viewModel.mcpConnectionTestState {
        case .idle: EmptyView()
        case .testing:
            HStack { ProgressView().controlSize(.small); Text(L("agent.mcp.testing")).font(.subheadline) }
        case let .success(tools):
            TypefluxStatus(L("agent.mcp.testSuccess", tools.count), tone: .success)
            ForEach(tools) { tool in
                TypefluxSettingsRow(tool.name, description: tool.description) { EmptyView() }
            }
        case let .failure(message):
            Text(message).font(.subheadline).foregroundStyle(TypefluxColor.danger.color)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}
