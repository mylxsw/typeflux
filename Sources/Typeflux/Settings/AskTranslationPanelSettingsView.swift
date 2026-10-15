import SwiftUI

/// Both shortcut editors use the same assignments and conflict checker.
struct AskTranslationPanelSettingsView: View {
    @ObservedObject var model: AskTranslationSettingsModel
    @StateObject private var shortcuts: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var recording: AppHotkeyAction?
    @State private var notice: String?

    init(model: AskTranslationSettingsModel) {
        self.model = model
        _shortcuts = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: model.store, workflows: .shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TFMetrics.sectionSpacing) {
            TFFormSection(title: L("ask.translation.panel.shortcuts")) {
                ForEach(Array(AppHotkeyAction.translation.enumerated()), id: \.element) { index, action in
                    if index > 0 { TFDivider.formWithIcon }
                    shortcut(action)
                }
            }
            if let notice {
                TFFieldMessage(text: notice, tone: .warning).padding(.horizontal, 4).padding(.top, -16)
            }
            TFFormSection(title: L("ask.translation.panel.preferences")) {
                TFFormRow(title: L("ask.translation.panel.position"), detail: L("ask.translation.panel.position.subtitle"),
                          icon: "macwindow") {
                    TFSegmentedControl(
                        options: AskTranslationPanelPosition.allCases.map { TFOption($0, $0.title) },
                        selection: Binding(get: { model.settings.panelPosition },
                                           set: { model.setPanelPreference($0, at: \.panelPosition) }),
                        identifier: { "ask.translation.panel.position." + $0.rawValue }
                    )
                }
                TFDivider.formWithIcon
                preference("height", icon: "arrow.up.and.down", keyPath: \.maxHeight,
                           values: AskTranslationPanelHeight.allCases, title: { $0.title })
                TFDivider.formWithIcon
                preference("autoCopy", icon: "doc.on.doc", keyPath: \.autoCopy,
                           values: AskTranslationAutoCopy.allCases, title: { $0.title })
                TFDivider.formWithIcon
                preference("keep", icon: "clock", keyPath: \.keepState,
                           values: AskTranslationKeepState.allCases, title: { $0.title })
                TFDivider.formWithIcon
                TFFormRow(title: L("ask.settings.plugins.translate.second"),
                          detail: L("ask.settings.plugins.translate.secondSubtitle"), icon: "globe") {
                    TFPopUpButton(
                        title: L("ask.settings.plugins.translate.second"),
                        options: AskTranslationLanguages.common.map {
                            TFOption($0, AskTranslationLanguages.name($0, in: AppLocalization.shared.language))
                        },
                        selection: Binding(get: { model.secondLanguage }, set: model.setSecondLanguage),
                        width: TFMetrics.formControlWidth
                    )
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
        TFFormRow(title: L("ask.translation.panel." + key), detail: L("ask.translation.panel." + key + ".subtitle"),
                  icon: icon) {
            TFPopUpButton(title: L("ask.translation.panel." + key),
                          options: values.map { TFOption($0, title($0)) },
                          selection: Binding(get: { model.settings[keyPath: keyPath] },
                                             set: { model.setPanelPreference($0, at: keyPath) }),
                          width: TFMetrics.formControlWidth,
                          identifier: "ask.translation.panel.setting." + key)
        }
    }

    private func shortcut(_ action: AppHotkeyAction) -> some View {
        TFFormRow(title: action.title, detail: L("hotkeys.action." + action.rawValue + ".subtitle"),
                  icon: HotkeySettingsPresentation.icon(of: action)) {
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
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(L("hotkeys.recordAccessibility", action.title))
            .accessibilityIdentifier("ask.translation.shortcut." + action.rawValue)
            TFButton(title: L("settings.shortcuts.unset"), systemImage: "xmark", kind: .plain, size: .small,
                     iconOnly: true) {
                if recording == action {
                    recorder.stop(); recording = nil
                }
                shortcuts.unsetHotkey(for: action)
            }
            .disabled(shortcuts.row(for: .action(action))?.binding == nil)
        }
    }
}
