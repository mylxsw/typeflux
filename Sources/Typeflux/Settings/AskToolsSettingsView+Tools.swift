import AppKit
import SwiftUI

/// The capability panes: web search, file access, code execution, and computer and browser control.
/// Each has a header with state and the configuration needed by that capability.
extension AskToolsSettingsView {
    func status(of capability: AgentCapability) -> AgentCapabilityStatus {
        AgentCapabilityStatus.status(of: capability, inputs: capabilityInputs)
    }

    func capabilityHeader(_ capability: AgentCapability) -> TFPaneHeader<TFStatusLabel> {
        TFPaneHeader(systemImage: capability.symbol, title: capability.title) {
            status(of: capability).statusLabel
        }
    }

    // MARK: - Web search

    @ViewBuilder var searchPane: some View {
        TFPaneHeader(systemImage: AgentCapability.webSearch.symbol, title: AgentCapability.webSearch.title) {
            status(of: .webSearch).statusLabel
            TFSwitch(title: AgentCapability.webSearch.title,
                     isOn: Binding(get: { searchProvider != .none }, set: setSearchEnabled))
        }
        if searchProvider == .none {
            TFNotice(text: L("agent.search.off"))
        } else {
            AgentSearchForm(
                provider: Binding(get: { searchProvider }, set: setSearchProvider),
                apiKey: Binding(get: { searchKey }, set: { searchKey = $0; saveSearchKey() }),
                cloudflare: Binding(get: { cloudflareSearch }, set: { cloudflareSearch = $0; search.cloudflare = $0 }),
                missing: missingSearchFields,
                configuration: searchConfiguration
            )
        }
    }

    // MARK: - Files

    @ViewBuilder var filesPane: some View {
        capabilityHeader(.files)
        VStack(alignment: .leading, spacing: 8) {
            TFFormSection(title: L("ask.settings.folders.title"), count: folders.count) {
                if folders.isEmpty {
                    TFCardNote(text: L("agent.files.empty"))
                    TFDivider.form
                }
                ForEach(folders, id: \.self) { folder in
                    TFFormRow(title: (folder as NSString).lastPathComponent, valueText: folder, icon: "folder",
                              valueLineLimit: 1) {
                        TFButton(title: L("ask.remove"), systemImage: "minus", size: .small, iconOnly: true) {
                            removeFolder(folder)
                        }
                    }
                    TFDivider.formWithIcon
                }
                TFActionRow(systemImage: "plus", title: L("ask.settings.folders.add")) { addFolder() }
            }
            if let removedFolder {
                TFUndoBar(message: L("agent.files.removed", (removedFolder.path as NSString).lastPathComponent),
                          onUndo: undoRemoveFolder, onDismiss: { self.removedFolder = nil })
            }
        }
    }

    // MARK: - Code execution

    @ViewBuilder var codePane: some View {
        TFPaneHeader(systemImage: AgentCapability.codeExecution.symbol, title: AgentCapability.codeExecution.title) {
            status(of: .codeExecution).statusLabel
            TFSwitch(title: AgentCapability.codeExecution.title,
                     isOn: Binding(get: { codeEnabled }, set: setCodeExecution))
        }
    }

    // MARK: - Computer and browser control

    @ViewBuilder var automationPane: some View {
        TFPaneHeader(systemImage: AgentCapability.automation.symbol, title: AgentCapability.automation.title)
        TFFormSection(title: L("agent.automation.permissions")) {
            permissionRow(icon: "hand.tap", title: L("permission.accessibility.title"),
                          detail: L("agent.automation.accessibility"),
                          granted: accessibilityGranted, request: permissions.requestAccessibility)
            TFDivider.formWithIcon
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
        TFFormRow(title: title, detail: detail, icon: icon) {
            if granted {
                TFStatusLabel(text: L("permission.badge.granted"), level: .success)
            } else {
                TFButton(title: L("permission.action.openSettings")) { request() }
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            form
            footnote.padding(.horizontal, 4)
        }
        .onChange(of: provider) { _ in connection.reset() }
        .onChange(of: apiKey) { _ in connection.reset() }
        .onChange(of: cloudflare) { _ in connection.reset() }
        .onDisappear { connection.reset() }
    }

    private var form: some View {
        TFFormSection(title: L("agent.search.section")) {
            // Turning search off is the pane's switch, so only real providers are offered here.
            TFFormRow(title: L("ask.settings.search.provider"), icon: "globe") {
                TFSegmentedControl(
                    options: AskSearchSettings.Provider.allCases.filter { $0 != .none }
                        .map { TFOption($0, AgentCapabilityStatus.searchProviderName($0)) },
                    selection: $provider
                )
            }
            if provider != .none {
                TFDivider.formWithIcon
                TFFormRow(title: AgentSearchField.apiKey.title(for: provider), icon: "key", isRequired: true,
                          controlWidth: .wide) {
                    TFSecureField(placeholder: provider == .cloudflare
                        ? L("agent.search.cloudflare.tokenPlaceholder") : L("agent.search.keyPlaceholder"),
                        text: $apiKey)
                }
                if provider == .cloudflare {
                    AskCloudflareSearchSettingsView(configuration: $cloudflare)
                }
                TFDivider.form
                testBar
            }
        }
    }

    private var testBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: TFMetrics.toolbarSpacing) {
                TFButton(title: L(connection.testing ? "ask.settings.search.cloudflare.testing"
                             : "ask.settings.search.cloudflare.test"),
                         isLoading: connection.testing) {
                    connection.start(configuration)
                }
                .disabled(connection.testing || !missing.isEmpty)
                if !missing.isEmpty {
                    TFFieldMessage(text: L("agent.search.missing",
                                           missing.map { $0.title(for: provider) }
                                               .joined(separator: L("agent.listSeparator"))),
                                   tone: .hint)
                }
                Spacer(minLength: 0)
            }
            if let result = connection.result {
                TFNotice(text: result, tone: connection.succeeded == true ? .success : .danger)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private var footnote: some View {
        if provider == .cloudflare {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TFFootnote(text: L("agent.search.cloudflare.help"))
                TFButton(title: L("ask.settings.search.cloudflare.guide"), kind: .link, size: .small) {
                    NSWorkspace.shared.open(URL(string: "https://developers.cloudflare.com/web-search/how-to-use/")!)
                }
            }
        } else if let url = Self.keyURL(for: provider) {
            TFButton(title: L("agent.search.getKey", AgentCapabilityStatus.searchProviderName(provider)),
                     kind: .link, size: .small) { NSWorkspace.shared.open(url) }
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
