import AppKit
import SwiftUI

/// The Built-in Tools tab: web search, file access, code execution, the launcher's
/// calculator and application search, and computer and browser control.
extension AskToolsSettingsView {
    @ViewBuilder var toolSections: some View {
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "globe", title: L("agent.capability.webSearch.title"),
                                 subtitle: L("agent.search.subtitle"), subtitleLineLimit: nil) {
                    let status = AgentCapabilityStatus.status(of: .webSearch, inputs: capabilityInputs)
                    AgentStatusBadge(level: status.level, label: status.label)
                }
                AgentSearchForm(
                    provider: Binding(get: { searchProvider }, set: setSearchProvider),
                    apiKey: Binding(get: { searchKey }, set: { searchKey = $0; saveSearchKey() }),
                    cloudflare: Binding(get: { cloudflareSearch }, set: { cloudflareSearch = $0; search.cloudflare = $0 }),
                    missing: missingSearchFields,
                    configuration: searchConfiguration
                )
                .padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 16)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            AgentSettingsSection(title: L("agent.capability.files.title"),
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
            AgentFlowLayout {
                AgentFactChip(text: L("agent.files.rule.scope"), systemImage: "checkmark")
                AgentFactChip(text: L("agent.files.rule.read"))
                AgentFactChip(text: L("agent.files.rule.write"))
            }
            if let removedFolder {
                AgentUndoBanner(message: L("agent.files.removed", (removedFolder.path as NSString).lastPathComponent),
                                onUndo: undoRemoveFolder, onDismiss: { self.removedFolder = nil })
            }
        }

        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "terminal", title: L("agent.capability.code.title"),
                                 subtitle: L("agent.code.subtitle"), subtitleLineLimit: nil) {
                    Toggle("", isOn: Binding(get: { codeEnabled }, set: setCodeExecution))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("agent.capability.code.title"))
                }
                if codeEnabled {
                    AgentFlowLayout {
                        AgentFactChip(text: L("agent.code.rule.network"), systemImage: "lock.shield")
                        AgentFactChip(text: L("agent.code.rule.home"), systemImage: "lock.shield")
                        AgentFactChip(text: L("agent.code.rule.confirm"), systemImage: "lock.shield")
                    }
                    .padding(.leading, 66).padding(.trailing, 18).padding(.bottom, 14)
                }
            }
        }

        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "plus.forwardslash.minus", title: L("ask.settings.quick.calculator.title"),
                                 subtitle: L("ask.settings.quick.calculator.subtitle"), subtitleLineLimit: nil) {
                    Toggle("", isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.calculator.title"))
                }
                ModelRowDivider(leading: 66)
                AgentSettingsRow(icon: "square.grid.2x2", title: L("ask.settings.quick.apps.title"),
                                 subtitle: L("ask.settings.quick.apps.subtitle"), subtitleLineLimit: nil) {
                    Toggle("", isOn: Binding(get: { quickAppsEnabled }, set: setQuickApps))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.apps.title"))
                }
            }
        }

        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "cursorarrow.click.2", title: L("agent.capability.automation.title"),
                                 subtitle: L("agent.automation.subtitle"), subtitleLineLimit: nil) {
                    let status = AgentCapabilityStatus.status(of: .automation, inputs: capabilityInputs)
                    AgentStatusBadge(level: status.level, label: status.label)
                }
                ModelRowDivider(leading: 66)
                permissionRow(title: L("permission.accessibility.title"), detail: L("agent.automation.accessibility"),
                              granted: accessibilityGranted, request: permissions.requestAccessibility)
                ModelRowDivider(leading: 66)
                permissionRow(title: L("agent.automation.screen.title"), detail: L("agent.automation.screen"),
                              granted: screenRecordingGranted, request: permissions.requestScreenRecording)
            }
        }
        // Permissions change in System Settings; re-read them when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = permissions.accessibilityGranted()
            screenRecordingGranted = permissions.screenRecordingGranted()
        }
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                               request: @escaping @MainActor () -> Void) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                Text(detail).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            Spacer()
            if granted {
                AgentStatusBadge(level: .ready, label: L("permission.badge.granted"))
            } else {
                Button(L("permission.action.openSettings")) { request() }.buttonStyle(ModelActionStyle())
            }
        }
        .padding(.leading, 66).padding(.trailing, 18).padding(.vertical, 12)
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
            ModelSegmentedControl(
                options: AskSearchSettings.Provider.allCases.map { (label: AgentCapabilityStatus.searchProviderName($0), value: $0) },
                selection: $provider
            )
            if provider == .none {
                Text(L("agent.search.off")).font(.system(size: 12)).foregroundStyle(StudioTheme.textTertiary)
            } else {
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
