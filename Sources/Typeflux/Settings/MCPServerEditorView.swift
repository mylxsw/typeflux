import SwiftUI

/// MCP connection form with the same fields, cards and actions as model endpoint settings.
struct MCPServerEditorView: View {
    @ObservedObject var viewModel: StudioViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L(viewModel
                    .mcpDraftEditingServerID == nil ? "agent.mcp.dialog.addTitle" : "agent.mcp.dialog.editTitle"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    connectionCard
                    ModelSurface {
                        VStack(spacing: 0) {
                            settingRow("agent.mcp.enabled.title", subtitle: "agent.mcp.enabled.subtitle",
                                       selection: $viewModel.mcpDraftEnabled)
                            ModelRowDivider()
                            settingRow("agent.mcp.autoConnect.title", subtitle: "agent.mcp.autoConnect.subtitle",
                                       selection: $viewModel.mcpDraftAutoConnect)
                        }
                    }
                    mcpConnectionTestResultView
                }.padding(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            actions
        }
        .padding(24)
        .frame(width: 520, height: min(640, max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 120)))
        .background(ModelVisualStyle.canvas)
        .onDisappear { viewModel.resetMCPDraftConnectionTest() }
        .onChange(of: connectionFields) { _ in viewModel.resetMCPDraftConnectionTest() }
    }

    private var connectionFields: [String] {
        [String(describing: viewModel.mcpDraftTransportType), viewModel.mcpDraftStdioCommand,
         viewModel.mcpDraftStdioArgs, viewModel.mcpDraftStdioEnv,
         viewModel.mcpDraftHTTPURL, viewModel.mcpDraftHTTPHeaders]
    }

    private var connectionCard: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                formRow("agent.mcp.name") {
                    TextField(L("agent.mcp.namePlaceholder"), text: $viewModel.mcpDraftName)
                        .textFieldStyle(ModelFieldStyle(monospaced: false))
                }
                ModelRowDivider()
                formRow("agent.mcp.transportType") {
                    SettingsMenuPicker(title: L("agent.mcp.transportType"),
                                       options: [(label: L("agent.mcp.transport.stdio"), value: MCPTransportType.stdio),
                                                 (label: L("agent.mcp.transport.http"), value: MCPTransportType.http)],
                                       selection: $viewModel.mcpDraftTransportType)
                }
                ModelRowDivider()
                if viewModel.mcpDraftTransportType == .stdio {
                    formRow("agent.mcp.stdio.command") {
                        TextField("/usr/local/bin/my-mcp-server", text: $viewModel.mcpDraftStdioCommand)
                            .textFieldStyle(ModelFieldStyle())
                    }
                    ModelRowDivider()
                    formRow("agent.mcp.stdio.args") {
                        TextField("--port 3000 --verbose", text: $viewModel.mcpDraftStdioArgs)
                            .textFieldStyle(ModelFieldStyle())
                    }
                    ModelRowDivider()
                    keyValueEditor(
                        label: "agent.mcp.stdio.env",
                        placeholder: "NODE_ENV",
                        text: $viewModel.mcpDraftStdioEnv
                    )
                    .id(MCPTransportType.stdio)
                } else {
                    formRow("agent.mcp.http.url") {
                        TextField("https://mcp.example.com/sse", text: $viewModel.mcpDraftHTTPURL)
                            .textFieldStyle(ModelFieldStyle())
                    }
                    ModelRowDivider()
                    keyValueEditor(
                        label: "agent.mcp.http.headers",
                        placeholder: "Authorization",
                        text: $viewModel.mcpDraftHTTPHeaders
                    )
                    .id(MCPTransportType.http)
                }
            }
        }
    }

    private func formRow(_ key: String, @ViewBuilder field: () -> some View) -> some View {
        AgentFormRow(label: L(key), labelWidth: 100, field: field)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .accessibilityElement(children: .contain)
    }

    private func keyValueEditor(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(label)).font(.system(size: 13)).foregroundStyle(StudioTheme.textSecondary)
            MCPKeyValueEditor(text: text, keyPlaceholder: placeholder, valuePlaceholder: L("agent.mcp.kv.value"))
        }.padding(18)
    }

    private func settingRow(_ title: String, subtitle: String, selection: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                Text(L(subtitle)).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(L(title), isOn: selection).labelsHidden().toggleStyle(.switch).accessibilityLabel(L(title))
        }.padding(18)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L("common.cancel"), action: closeEditor).buttonStyle(ModelActionStyle())
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            Button {
                viewModel.testMCPDraftConnection()
            } label: {
                HStack(spacing: 6) {
                    if viewModel.mcpConnectionTestState == .testing {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Text(L(viewModel
                            .mcpConnectionTestState == .testing ? "agent.mcp.testing" : "agent.mcp.testConnection"))
                }
            }
            .buttonStyle(ModelActionStyle())
            .accessibilityLabel(L(viewModel.mcpConnectionTestState == .testing
                    ? "agent.mcp.testing" : "agent.mcp.testConnection"))
            .disabled(!viewModel.canSaveMCPDraft || viewModel.mcpConnectionTestState == .testing)
            Button(L("common.save")) {
                viewModel.saveMCPDraft()
                closeEditor()
            }
            .buttonStyle(ModelActionStyle(primary: true)).disabled(!viewModel.canSaveMCPDraft)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func closeEditor() {
        // A sheet's disappearance can be delayed by its dismissal animation.
        viewModel.resetMCPDraftConnectionTest()
        onClose()
    }

    @ViewBuilder
    private var mcpConnectionTestResultView: some View {
        switch viewModel.mcpConnectionTestState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: StudioTheme.Spacing.xSmall) {
                ProgressView().controlSize(.small)
                Text(L("agent.mcp.testing"))
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
        case let .success(tools):
            VStack(alignment: .leading, spacing: StudioTheme.Spacing.small) {
                HStack(spacing: StudioTheme.Spacing.xSmall) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StudioTheme.success)
                    Text(L("agent.mcp.testSuccess", tools.count))
                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                        .foregroundStyle(StudioTheme.textPrimary)
                }
                if !tools.isEmpty {
                    VStack(alignment: .leading, spacing: StudioTheme.Spacing.xxSmall) {
                        ForEach(tools) { tool in
                            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(StudioTheme.textTertiary)
                                    .frame(width: 14, alignment: .center)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.name)
                                        .font(.studioBody(StudioTheme.Typography.caption, weight: .semibold))
                                        .foregroundStyle(StudioTheme.textPrimary)
                                    if !tool.description.isEmpty {
                                        Text(tool.description)
                                            .font(.studioBody(StudioTheme.Typography.caption, weight: .regular))
                                            .foregroundStyle(StudioTheme.textSecondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                    .padding(StudioTheme.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                            .fill(StudioTheme.controlSurface)
                    )
                }
            }
        case let .failure(message):
            HStack(alignment: .top, spacing: StudioTheme.Spacing.xSmall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StudioTheme.danger)
                Text(message)
                    .font(.studioBody(StudioTheme.Typography.caption))
                    .foregroundStyle(StudioTheme.danger)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}
