import SwiftUI

/// Launcher → Clipboard: recording, retention and storage, and how the panel behaves.
struct ClipboardSettingsView: View {
    @StateObject private var model: ClipboardSettingsModel
    /// Opens the shortcut settings, where the panel's shortcut is recorded.
    var onEditShortcut: () -> Void

    init(settings: SettingsStore, history: ClipboardHistoryStore? = nil, onEditShortcut: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: ClipboardSettingsModel(store: settings, history: history))
        self.onEditShortcut = onEditShortcut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelSectionLabel(title: L("clipboard.settings.section.recording"))
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    toggleRow(icon: "doc.on.clipboard", title: "history.clipboard.title",
                              subtitle: nil,
                              isOn: Binding(get: { model.historyEnabled }, set: model.setHistoryEnabled))
                    ModelRowDivider(leading: 66)
                    shortcutRow
                    ModelRowDivider(leading: 66)
                    row(icon: "pause.circle", title: "clipboard.settings.pause",
                        subtitle: nil) {
                        SettingsMenuPicker(title: L("clipboard.settings.pause"), options: model.pauseOptions,
                                           selection: Binding(get: { model.pause }, set: model.setPause))
                            .frame(width: 200)
                    }
                }
            }
            ModelSectionLabel(title: L("clipboard.settings.section.storage")).padding(.top, 14)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    row(icon: "calendar", title: "clipboard.settings.retention",
                        subtitle: nil) {
                        SettingsMenuPicker(title: L("clipboard.settings.retention"),
                                           options: ClipboardRetention.allCases.map { ($0.title, $0) },
                                           selection: Binding(get: { model.retention }, set: model.setRetention))
                            .frame(width: 200)
                    }
                    ModelRowDivider(leading: 66)
                    row(icon: "list.number", title: "clipboard.settings.maxItems",
                        subtitle: "clipboard.settings.maxItems.subtitle") {
                        SettingsMenuPicker(title: L("clipboard.settings.maxItems"),
                                           options: ClipboardItemLimit.options.map { ("\($0)", $0) },
                                           selection: Binding(get: { model.maxItems }, set: model.setMaxItems))
                            .frame(width: 200)
                    }
                    ModelRowDivider(leading: 66)
                    row(icon: "internaldrive", title: "clipboard.settings.storage",
                        subtitle: "clipboard.settings.storage.subtitle") {
                        SettingsMenuPicker(title: L("clipboard.settings.storage"),
                                           options: ClipboardStorageLimit.allCases.map { ($0.title, $0) },
                                           selection: Binding(get: { model.storageLimit }, set: model.setStorageLimit))
                            .frame(width: 200)
                    }
                    ModelRowDivider(leading: 66)
                    toggleRow(icon: "textformat", title: "clipboard.settings.plainTextOnly",
                              subtitle: "clipboard.settings.plainTextOnly.subtitle",
                              isOn: Binding(get: { model.plainTextOnly }, set: model.setPlainTextOnly))
                }
            }
            ModelSectionLabel(title: L("clipboard.settings.section.panel")).padding(.top, 14)
            ModelSurface {
                VStack(alignment: .leading, spacing: 0) {
                    toggleRow(icon: "cursorarrow.click", title: "clipboard.settings.singleClick",
                              subtitle: nil,
                              isOn: Binding(get: { model.singleClickPastes }, set: model.setSingleClickPastes))
                    ModelRowDivider(leading: 66)
                    toggleRow(icon: "sidebar.right", title: "clipboard.settings.preview",
                              subtitle: nil,
                              isOn: Binding(get: { model.showsPreview }, set: model.setShowsPreview))
                    ModelRowDivider(leading: 66)
                    toggleRow(icon: "pin.slash", title: "clipboard.settings.firstUnpinned",
                              subtitle: nil,
                              isOn: Binding(get: { model.selectsFirstUnpinned }, set: model.setSelectsFirstUnpinned))
                    ModelRowDivider(leading: 66)
                    row(icon: "macwindow", title: "clipboard.settings.position", subtitle: nil) {
                        SettingsMenuPicker(title: L("clipboard.settings.position"),
                                           options: ClipboardPanelPosition.allCases.map { ($0.title, $0) },
                                           selection: Binding(
                                               get: { model.panelPosition }, set: model.setPanelPosition
                                           ))
                            .frame(width: 200)
                    }
                }
            }
            ModelSectionLabel(title: L("clipboard.settings.section.ignored")).padding(.top, 14)
            ClipboardIgnoredAppsSection(model: model)
            if model.history != nil {
                ModelSectionLabel(title: L("clipboard.settings.section.usage")).padding(.top, 14)
                ClipboardUsageSection(model: model)
            }
        }
        .onAppear {
            model.reloadPause()
            model.reloadUsage()
        }
    }

    private var shortcutRow: some View {
        row(icon: "keyboard", title: "clipboard.settings.shortcut", subtitle: "clipboard.settings.shortcut.subtitle") {
            HStack(spacing: 8) {
                Text(model.store.historyHotkey.map(HotkeyFormat.display) ?? L("clipboard.settings.shortcut.none"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(StudioTheme.textSecondary)
                Button(L("clipboard.settings.shortcut.change"), action: onEditShortcut)
            }
        }
    }

    private func row(
        icon: String, title: String, subtitle: String?, @ViewBuilder trailing: () -> some View
    ) -> some View {
        AgentSettingsRow(icon: icon, title: L(title), subtitle: subtitle.map { L($0) }, subtitleLineLimit: nil,
                         trailing: trailing)
    }

    private func toggleRow(icon: String, title: String, subtitle: String?, isOn: Binding<Bool>) -> some View {
        AgentSettingsRow(icon: icon, title: L(title), subtitle: subtitle.map { L($0) }, subtitleLineLimit: nil) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).accessibilityLabel(L(title))
        }
    }
}
