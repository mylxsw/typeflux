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
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection(title: L("clipboard.settings.section.recording")) {
                toggleRow(icon: "doc.on.clipboard", title: "history.clipboard.title",
                          isOn: Binding(get: { model.historyEnabled }, set: model.setHistoryEnabled))
                TFDivider.formWithIcon
                shortcutRow
                TFDivider.formWithIcon
                pickerRow(icon: "pause.circle", title: "clipboard.settings.pause",
                          options: model.pauseOptions.map { TFOption($0.value, $0.label) },
                          selection: Binding(get: { model.pause }, set: model.setPause))
            }
            TFFormSection(title: L("clipboard.settings.section.storage")) {
                pickerRow(icon: "calendar", title: "clipboard.settings.retention",
                          options: ClipboardRetention.allCases.map { TFOption($0, $0.title) },
                          selection: Binding(get: { model.retention }, set: model.setRetention))
                TFDivider.formWithIcon
                pickerRow(icon: "list.number", title: "clipboard.settings.maxItems",
                          detail: "clipboard.settings.maxItems.subtitle",
                          options: ClipboardItemLimit.options.map { TFOption($0, "\($0)") },
                          selection: Binding(get: { model.maxItems }, set: model.setMaxItems))
                TFDivider.formWithIcon
                pickerRow(icon: "internaldrive", title: "clipboard.settings.storage",
                          detail: "clipboard.settings.storage.subtitle",
                          options: ClipboardStorageLimit.allCases.map { TFOption($0, $0.title) },
                          selection: Binding(get: { model.storageLimit }, set: model.setStorageLimit))
                TFDivider.formWithIcon
                toggleRow(icon: "doc.plaintext", title: "clipboard.settings.plainTextOnly",
                          detail: "clipboard.settings.plainTextOnly.subtitle",
                          isOn: Binding(get: { model.plainTextOnly }, set: model.setPlainTextOnly))
            }
            TFFormSection(title: L("clipboard.settings.section.panel")) {
                toggleRow(icon: "cursorarrow.click", title: "clipboard.settings.singleClick",
                          isOn: Binding(get: { model.singleClickPastes }, set: model.setSingleClickPastes))
                TFDivider.formWithIcon
                toggleRow(icon: "sidebar.right", title: "clipboard.settings.preview",
                          isOn: Binding(get: { model.showsPreview }, set: model.setShowsPreview))
                TFDivider.formWithIcon
                toggleRow(icon: "pin.slash", title: "clipboard.settings.firstUnpinned",
                          isOn: Binding(get: { model.selectsFirstUnpinned }, set: model.setSelectsFirstUnpinned))
                TFDivider.formWithIcon
                pickerRow(icon: "macwindow", title: "clipboard.settings.position",
                          options: ClipboardPanelPosition.allCases.map { TFOption($0, $0.title) },
                          selection: Binding(get: { model.panelPosition }, set: model.setPanelPosition))
            }
            ClipboardIgnoredAppsSection(model: model)
            if model.history != nil {
                ClipboardUsageSection(model: model)
            }
        }
        .onAppear {
            model.reloadPause()
            model.reloadUsage()
        }
    }

    private var shortcutRow: some View {
        TFFormRow(title: L("clipboard.settings.shortcut"), detail: L("clipboard.settings.shortcut.subtitle"),
                  icon: "keyboard") {
            Text(model.store.historyHotkey.map(HotkeyFormat.display) ?? L("clipboard.settings.shortcut.none"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(TFColors.textSecondary)
            TFButton(title: L("clipboard.settings.shortcut.change"), size: .small, action: onEditShortcut)
        }
    }

    private func pickerRow<Value: Hashable>(
        icon: String, title: String, detail: String? = nil, options: [TFOption<Value>], selection: Binding<Value>
    ) -> some View {
        TFFormRow(title: L(title), detail: detail.map { L($0) }, icon: icon) {
            TFPopUpButton(title: L(title), options: options, selection: selection, width: TFMetrics.formControlWidth)
        }
    }

    private func toggleRow(icon: String, title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        TFFormRow(title: L(title), detail: detail.map { L($0) }, icon: icon) {
            TFSwitch(title: L(title), isOn: isOn)
        }
    }
}
