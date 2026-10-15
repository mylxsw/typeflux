import SwiftUI

/// Both shortcut editors use the same assignments and conflict checker.
struct AskTranslationPanelSettingsView: View {
    @ObservedObject var model: AskTranslationSettingsModel
    @StateObject private var shortcuts: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recording: AppHotkeyAction?
    @State private var notice: String?
    @State private var hoveredShortcut: AppHotkeyAction?

    init(model: AskTranslationSettingsModel) {
        self.model = model
        _shortcuts = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: model.store, workflows: .shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModelSectionLabel(title: L("ask.translation.panel.shortcuts"))
            ModelSurface {
                VStack(spacing: 0) {
                    ForEach(Array(AppHotkeyAction.translation.enumerated()), id: \.element) { index, action in
                        if index > 0 {
                            ModelRowDivider(leading: 18)
                        }
                        shortcut(action)
                    }
                }
            }
            if let notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(StudioTheme.warning)
            }
            ModelSectionLabel(title: L("ask.translation.panel.preferences")).padding(.top, 14)
            ModelSurface {
                VStack(spacing: 0) {
                    AgentSettingsRow(icon: "macwindow", title: L("ask.translation.panel.position"),
                                     subtitle: L("ask.translation.panel.position.subtitle"), subtitleLineLimit: nil) {
                        StudioSegmentedPicker(
                            options: AskTranslationPanelPosition.allCases.map { (label: $0.title, value: $0) },
                            selection: Binding(get: { model.settings.panelPosition },
                                               set: {
                                                   model.setPanelPreference($0, at: \.panelPosition)
                                               }),
                            size: .compact,
                            optionIdentifier: { "ask.translation.panel.position." + $0.rawValue }
                        )
                    }
                    ModelRowDivider(leading: 18)
                    preference("height", icon: "arrow.up.and.down", keyPath: \.maxHeight,
                               values: AskTranslationPanelHeight.allCases, title: { $0.title })
                    ModelRowDivider(leading: 18)
                    preference("autoCopy", icon: "doc.on.doc", keyPath: \.autoCopy,
                               values: AskTranslationAutoCopy.allCases, title: { $0.title })
                    ModelRowDivider(leading: 18)
                    preference("keep", icon: "clock", keyPath: \.keepState,
                               values: AskTranslationKeepState.allCases, title: { $0.title })
                    ModelRowDivider(leading: 18)
                    AgentSettingsRow(icon: "globe", title: L("ask.settings.plugins.translate.second"),
                                     subtitle: L("ask.settings.plugins.translate.secondSubtitle"),
                                     subtitleLineLimit: nil) {
                        SettingsMenuPicker(
                            title: L("ask.settings.plugins.translate.second"),
                            options: AskTranslationLanguages.common.map { (
                                label: AskTranslationLanguages.name($0, in: AppLocalization.shared.language),
                                value: $0
                            ) },
                            selection: Binding(get: { model.secondLanguage }, set: model.setSecondLanguage)
                        ).frame(width: 180)
                    }
                }
            }
        }
        .onDisappear { recorder.stop(); recording = nil }
    }

    private func preference<Value: Hashable>(
        _ key: String,
        icon: String,
        keyPath: WritableKeyPath<AskTranslationSettings, Value>,
        values: [Value],
        title: (Value) -> String
    ) -> some View {
        AgentSettingsRow(icon: icon, title: L("ask.translation.panel." + key),
                         subtitle: L("ask.translation.panel." + key + ".subtitle"), subtitleLineLimit: nil) {
            SettingsMenuPicker(title: L("ask.translation.panel." + key),
                               options: values.map { (label: title($0), value: $0) },
                               selection: Binding(
                                   get: { model.settings[keyPath: keyPath] },
                                   set: { model.setPanelPreference($0, at: keyPath) }
                               ))
                               .frame(width: 180)
                               .accessibilityIdentifier("ask.translation.panel.setting." + key)
        }
    }

    private func shortcut(_ action: AppHotkeyAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: HotkeySettingsPresentation.icon(of: action))
                .foregroundStyle(StudioTheme.textSecondary).frame(width: 18)
            HStack(spacing: 6) {
                Text(action.title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.textPrimary)
                    .accessibilityHint(L("hotkeys.action." + action.rawValue + ".subtitle"))
                SettingsDescriptionHint(detail: L("hotkeys.action." + action.rawValue + ".subtitle"),
                                        visible: hoveredShortcut == action)
            }
            Spacer()
            Button {
                if recording == action {
                    recorder.stop(); recording = nil; return
                }
                recording = action
                notice = nil
                recorder.start { binding in
                    recording = nil
                    notice = shortcuts.setHotkey(binding, for: action)
                    if notice == nil, HotkeyConflictChecker.isCommonSystemShortcut(binding) {
                        notice = L("hotkeys.conflict.system")
                    }
                }
            } label: {
                HotkeyKeysView(binding: shortcuts.row(for: .action(action))?.binding, isRecording: recording == action)
                    .frame(width: 170, alignment: .trailing)
            }
            .buttonStyle(.plain).accessibilityLabel(L("hotkeys.recordAccessibility", action.title))
            .accessibilityIdentifier("ask.translation.shortcut." + action.rawValue)
            Button {
                if recording == action {
                    recorder.stop(); recording = nil
                }
                shortcuts.unsetHotkey(for: action)
            } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary)
                .disabled(shortcuts.row(for: .action(action))?.binding == nil)
                .help(L("settings.shortcuts.unset"))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .onHover { hoveredShortcut = $0 ? action : nil }
    }
}
