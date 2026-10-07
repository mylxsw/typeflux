import AppKit
import SwiftUI

/// The capability panes: web search, file access, code execution, and computer and browser control.
/// Each has a header with state and the configuration needed by that capability.
extension AskToolsSettingsView {
    func status(of capability: AgentCapability) -> AgentCapabilityStatus {
        AgentCapabilityStatus.status(of: capability, inputs: capabilityInputs)
    }

    func capabilityHeader(_ capability: AgentCapability) -> AgentPaneHeader<AgentStatusBadge> {
        let state = status(of: capability)
        return AgentPaneHeader(symbol: capability.symbol, title: capability.title) {
            AgentStatusBadge(level: state.level, label: state.label)
        }
    }

    // MARK: - Web search

    @ViewBuilder var searchPane: some View {
        let state = status(of: .webSearch)
        AgentPaneHeader(symbol: AgentCapability.webSearch.symbol, title: AgentCapability.webSearch.title) {
            AgentStatusBadge(level: state.level, label: state.label)
            Toggle("", isOn: Binding(get: { searchProvider != .none }, set: setSearchEnabled))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(AgentCapability.webSearch.title)
        }
        if searchProvider == .none {
            AgentInfoNote(text: L("agent.search.off"))
        } else {
            AgentSettingsSection(title: L("agent.search.section")) {
                AgentSearchForm(
                    provider: Binding(get: { searchProvider }, set: setSearchProvider),
                    apiKey: Binding(get: { searchKey }, set: { searchKey = $0; saveSearchKey() }),
                    cloudflare: Binding(get: { cloudflareSearch }, set: { cloudflareSearch = $0; search.cloudflare = $0 }),
                    missing: missingSearchFields,
                    configuration: searchConfiguration
                )
                .padding(18)
            }
        }
    }

    // MARK: - Files

    @ViewBuilder var filesPane: some View {
        capabilityHeader(.files)
        VStack(alignment: .leading, spacing: 8) {
            AgentSettingsSection(title: L("ask.settings.folders.title"),
                                 detail: L("agent.status.files.count", folders.count)) {
                if folders.isEmpty {
                    AgentSettingsEmptyRow(text: L("agent.files.empty"))
                    ModelRowDivider(leading: 18)
                }
                ForEach(folders, id: \.self) { folder in
                    AgentSettingsRow(icon: "folder", title: (folder as NSString).lastPathComponent,
                                     subtitle: folder, subtitleLineLimit: 1) {
                        AgentSettingsIconButton(systemImage: "minus", help: L("ask.remove")) { removeFolder(folder) }
                    }
                    ModelRowDivider(leading: 66)
                }
                AgentSettingsActionRow(icon: "plus", title: L("ask.settings.folders.add")) { addFolder() }
            }
            if let removedFolder {
                AgentUndoBanner(message: L("agent.files.removed", (removedFolder.path as NSString).lastPathComponent),
                                onUndo: undoRemoveFolder, onDismiss: { self.removedFolder = nil })
            }
        }
    }

    // MARK: - Code execution

    @ViewBuilder var codePane: some View {
        let state = status(of: .codeExecution)
        AgentPaneHeader(symbol: AgentCapability.codeExecution.symbol, title: AgentCapability.codeExecution.title) {
            AgentStatusBadge(level: state.level, label: state.label)
            Toggle("", isOn: Binding(get: { codeEnabled }, set: setCodeExecution))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(AgentCapability.codeExecution.title)
        }
    }

    // MARK: - Computer and browser control

    @ViewBuilder var automationPane: some View {
        capabilityHeader(.automation)
        AgentSettingsSection(title: L("agent.automation.permissions"), footnote: L("agent.automation.permissions.hint")) {
            permissionRow(icon: "hand.tap", title: L("permission.accessibility.title"), detail: L("agent.automation.accessibility"),
                          granted: accessibilityGranted, request: permissions.requestAccessibility)
            ModelRowDivider(leading: 66)
            permissionRow(icon: "rectangle.dashed.badge.record", title: L("agent.automation.screen.title"),
                          detail: L("agent.automation.screen"),
                          granted: screenRecordingGranted, request: permissions.requestScreenRecording)
        }
        // Permissions change in System Settings; re-read them when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = permissions.accessibilityGranted()
            screenRecordingGranted = permissions.screenRecordingGranted()
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool,
                               request: @escaping @MainActor () -> Void) -> some View {
        AgentSettingsRow(icon: icon, title: title, subtitle: detail) {
            if granted {
                AgentStatusBadge(level: .ready, label: L("permission.badge.granted"))
            } else {
                Button(L("permission.action.openSettings")) { request() }.buttonStyle(ModelActionStyle())
            }
        }
    }
}

/// A one-line explanation in an accent-tinted box, e.g. why a pane has nothing to set.
struct AgentInfoNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(ModelVisualStyle.accent)
            Text(text).foregroundStyle(StudioTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModelVisualStyle.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Provider choice, credentials and connection test for local web search.
struct AgentSearchForm: View {
    @Binding var provider: AskSearchSettings.Provider
    @Binding var apiKey: String
    @Binding var cloudflare: AskCloudflareSearchConfiguration
    let missing: [AgentSearchField]
    let configuration: AskSearchConfiguration
    @StateObject private var connection = AskCloudflareConnectionTest()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Turning search off is the pane's switch, so only real providers are offered here.
            ModelSegmentedControl(
                options: AskSearchSettings.Provider.allCases.filter { $0 != .none }
                    .map { (label: AgentCapabilityStatus.searchProviderName($0), value: $0) },
                selection: $provider
            )
            if provider != .none {
                AgentFormRow(label: AgentSearchField.apiKey.title(for: provider), required: true) {
                    SecureField(provider == .cloudflare ? L("agent.search.cloudflare.tokenPlaceholder") : L("agent.search.keyPlaceholder"),
                                text: $apiKey)
                        .textFieldStyle(ModelFieldStyle())
                }
                if provider == .cloudflare {
                    AskCloudflareSearchSettingsView(configuration: $cloudflare)
                }
                testBar
                footnote
            }
        }
        .onChange(of: provider) { _ in connection.reset() }
        .onChange(of: apiKey) { _ in connection.reset() }
        .onChange(of: cloudflare) { _ in connection.reset() }
        .onDisappear { connection.reset() }
    }

    private var testBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    connection.start(configuration)
                } label: {
                    HStack(spacing: 6) {
                        if connection.testing { ProgressView().controlSize(.small) }
                        Text(L(connection.testing ? "ask.settings.search.cloudflare.testing" : "ask.settings.search.cloudflare.test"))
                    }
                }
                .buttonStyle(ModelActionStyle())
                .disabled(connection.testing || !missing.isEmpty)
                if !missing.isEmpty {
                    Text(L("agent.search.missing", missing.map { $0.title(for: provider) }.joined(separator: L("agent.listSeparator"))))
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
                }
            }
            if let result = connection.result {
                let ok = connection.succeeded == true
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(result).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .foregroundStyle(ok ? StudioTheme.success : StudioTheme.danger)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((ok ? StudioTheme.success : StudioTheme.danger).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if provider == .cloudflare {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("agent.search.cloudflare.help")).fixedSize(horizontal: false, vertical: true)
                Link(L("ask.settings.search.cloudflare.guide"),
                     destination: URL(string: "https://developers.cloudflare.com/web-search/how-to-use/")!)
            }
            .font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
        } else if let url = Self.keyURL(for: provider) {
            Link(L("agent.search.getKey", AgentCapabilityStatus.searchProviderName(provider)), destination: url)
                .font(.system(size: 12))
        }
    }

    static func keyURL(for provider: AskSearchSettings.Provider) -> URL? {
        switch provider {
        case .tavily: URL(string: "https://app.tavily.com/")
        case .brave: URL(string: "https://api-dashboard.search.brave.com/")
        case .none, .cloudflare: nil
        }
    }
}
