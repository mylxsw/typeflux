import AppKit
import SwiftUI

/// The capability panes: web search, file access, code execution, and computer and browser control.
/// Each has a header with state and the configuration needed by that capability.
extension AskToolsSettingsView {
    func status(of capability: AgentCapability) -> AgentCapabilityStatus {
        AgentCapabilityStatus.status(of: capability, inputs: capabilityInputs)
    }

    func capabilityHeader(_ capability: AgentCapability) -> AgentPaneHeader<TypefluxStatus> {
        let state = status(of: capability)
        return AgentPaneHeader(symbol: capability.symbol, title: capability.title) {
            TypefluxStatus(state.label, tone: state.level.tone)
        }
    }

    // MARK: - Web search

    @ViewBuilder var searchPane: some View {
        let state = status(of: .webSearch)
        AgentPaneHeader(symbol: AgentCapability.webSearch.symbol, title: AgentCapability.webSearch.title) {
            TypefluxStatus(state.label, tone: state.level.tone)
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
                    cloudflare: Binding(get: { cloudflareSearch },
                                        set: { cloudflareSearch = $0; search.cloudflare = $0 }),
                    missing: missingSearchFields,
                    configuration: searchConfiguration
                )
            }
        }
    }

    // MARK: - Files

    @ViewBuilder var filesPane: some View {
        capabilityHeader(.files)
        Group {
            AgentSettingsSection(title: L("ask.settings.folders.title"),
                                 detail: L("agent.status.files.count", folders.count)) {
                if folders.isEmpty {
                    AgentSettingsEmptyRow(text: L("agent.files.empty"))
                }
                ForEach(folders, id: \.self) { folder in
                    AgentSettingsRow(icon: "folder", title: (folder as NSString).lastPathComponent,
                                     subtitle: folder, subtitleLineLimit: 1) {
                        TypefluxIconButton(L("ask.remove") + " " + folder,
                                           systemImage: "minus") { removeFolder(folder) }
                    }
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
            TypefluxStatus(state.label, tone: state.level.tone)
            Toggle("", isOn: Binding(get: { codeEnabled }, set: setCodeExecution))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(AgentCapability.codeExecution.title)
        }
    }

    // MARK: - Computer and browser control

    @ViewBuilder var automationPane: some View {
        capabilityHeader(.automation)
        AgentSettingsSection(title: L("agent.automation.permissions"),
                             footnote: L("agent.automation.permissions.hint")) {
            permissionRow(icon: "hand.tap", title: L("permission.accessibility.title"),
                          detail: L("agent.automation.accessibility"),
                          granted: accessibilityGranted, request: permissions.requestAccessibility)
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
                TypefluxStatus(L("permission.badge.granted"), tone: .success)
            } else {
                Button(L("permission.action.openSettings")) { request() }.buttonStyle(.bordered)
            }
        }
    }
}
