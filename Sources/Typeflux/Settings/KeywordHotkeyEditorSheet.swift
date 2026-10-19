import SwiftUI

/// Adds or edits one keyword shortcut: which keyword it runs and its keys. Pressing it
/// opens the launcher in that keyword and runs it on the selected text.
struct KeywordHotkeyEditorSheet: View {
    @ObservedObject var model: HotkeySettingsModel
    @State var draft: KeywordHotkeyDraft
    let onDone: () -> Void
    @StateObject private var recorder = HotkeyRecorder()

    private var result: HotkeyConflictChecker.Result? {
        draft.hotkey.binding.map { model.check($0, for: .keyword(draft.hotkey.id)) }
    }

    private var selected: KeywordHotkeyOption? {
        draft.selectedOption(in: model.options)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L(draft.isNew ? "hotkeys.keyword.sheet.addTitle" : "hotkeys.keyword.sheet.editTitle"))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 18)
            VStack(alignment: .leading, spacing: 14) {
                field(L("hotkeys.keyword.sheet.keyword")) { keywordPicker }
                field(L("hotkeys.keyword.sheet.shortcut")) { shortcutField }
            }
            .padding(.horizontal, 22)
            footer.padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
        }
        .frame(width: 480)
        .background(ModelVisualStyle.canvas)
        .onDisappear { recorder.stop() }
    }

    private var keywordPicker: some View {
        TFPopUpButton(title: L("hotkeys.keyword.sheet.keyword"), options: keywordOptions, selection: Binding(
            get: { selected?.id ?? "" },
            set: { id in
                if let option = model.options.first(where: { $0.id == id }) {
                    draft.select(option)
                }
            }
        ), width: 348, identifier: "hotkeys.keyword.sheet.keyword")
    }

    private var keywordOptions: [TFOption<String>] {
        var options = model.options.map { TFOption($0.id, optionLabel($0)) }
        if selected == nil {
            options.insert(TFOption("", draft.hotkey.keyword.isEmpty ? L("hotkeys.keyword.sheet.choose")
                : L("hotkeys.keyword.status.missing")), at: 0)
        }
        return options
    }

    private func optionLabel(_ option: KeywordHotkeyOption) -> String {
        let label = "\(option.keyword.keyword) · \(option.name)"
        return option.keyword.enabled ? label : label + " (" + L("hotkeys.keyword.sheet.keywordOff") + ")"
    }

    @ViewBuilder private var shortcutField: some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                HStack(spacing: 8) {
                    if draft.hotkey.binding == nil, !recorder.isRecording {
                        Image(systemName: "keyboard").foregroundStyle(StudioTheme.textSecondary)
                        Text(L("hotkeys.keyword.sheet.record"))
                            .font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                    } else {
                        HotkeyKeysView(binding: draft.hotkey.binding, isRecording: recorder.isRecording)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(minHeight: 40)
                .background(ModelVisualStyle.input,
                            in: RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: ModelVisualStyle.controlCornerRadius)
                    .strokeBorder(recorder.isRecording ? StudioTheme.accent : ModelVisualStyle.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("hotkeys.recordHelp"))
            .accessibilityLabel(L("hotkeys.keyword.sheet.record"))
            .accessibilityValue(recorder.isRecording ? L("hotkeys.recording")
                : draft.hotkey.binding.map(HotkeyFormat.display) ?? L("settings.shortcuts.none"))
            .accessibilityIdentifier("hotkeys.keyword.sheet.record")
            if draft.hotkey.binding != nil, !recorder.isRecording {
                Button { draft.hotkey.binding = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(StudioTheme.textTertiary)
                }
                .buttonStyle(.plain).help(L("settings.shortcuts.unset"))
            }
        }
        if recorder.isRecording {
            hint(L("hotkeys.recording.hint"))
        } else if let result, let problem = result.problem {
            Text(model.message(for: problem)).font(.system(size: 11.5)).foregroundStyle(StudioTheme.danger)
            if draft.keywordOwner(in: result) != nil {
                Toggle(L("hotkeys.keyword.sheet.takeKeys"), isOn: $draft.takesKeys)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .accessibilityIdentifier("hotkeys.keyword.sheet.takeKeys")
            }
        } else if result?.overridesSystemShortcut == true {
            Text(L("hotkeys.conflict.system")).font(.system(size: 11.5)).foregroundStyle(StudioTheme.warning)
        } else {
            hint(L("hotkeys.keyword.sheet.shortcutHint"))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !draft.isNew {
                Button(role: .destructive) {
                    model.delete(draft.hotkey.id)
                    onDone()
                } label: {
                    Text(L("hotkeys.keyword.delete")).foregroundStyle(StudioTheme.danger)
                }
                .buttonStyle(ModelActionStyle())
            }
            Spacer()
            Toggle(isOn: $draft.hotkey.enabled) {
                Text(L("ask.settings.keywords.enabled")).font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            .toggleStyle(.switch).controlSize(.small).padding(.trailing, 6)
            Button(L("ask.workflow.cancel"), action: onDone)
                .buttonStyle(ModelActionStyle())
                .keyboardShortcut(.cancelAction)
            Button(L(draft.isNew ? "ask.settings.keywords.sheet.add" : "ask.settings.keywords.save")) {
                model.save(draft.hotkey, takingFrom: draft.takesKeys ? draft.keywordOwner(in: result) : nil)
                onDone()
            }
            .buttonStyle(ModelActionStyle(primary: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!draft.canSave(with: result) || recorder.isRecording)
            .accessibilityIdentifier("hotkeys.keyword.sheet.save")
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            return
        }
        recorder.start { binding in draft.record(binding) }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(StudioTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
