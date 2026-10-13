import SwiftUI

/// Adds or edits one keyword shortcut: which keyword it runs and its keys. Pressing it
/// opens the launcher in that keyword and runs it on the selected text.
struct KeywordHotkeyEditorSheet: View {
    @ObservedObject var model: HotkeySettingsModel
    @State var draft: KeywordHotkeyDraft
    let onDone: () -> Void
    @State private var confirmsDeletion = false
    @StateObject private var recorder = HotkeyRecorder()

    private var result: HotkeyConflictChecker.Result? {
        draft.hotkey.binding.map { model.check($0, for: .keyword(draft.hotkey.id)) }
    }

    private var selected: KeywordHotkeyOption? {
        draft.selectedOption(in: model.options)
    }

    var body: some View {
        TypefluxSheet(title: L(draft.isNew ? "hotkeys.keyword.sheet.addTitle" : "hotkeys.keyword.sheet.editTitle"),
                      cancelTitle: L("ask.workflow.cancel"),
                      confirmTitle: L(draft.isNew ? "ask.settings.keywords.sheet.add" : "ask.settings.keywords.save"),
                      isConfirmEnabled: draft.canSave(with: result) && !recorder.isRecording,
                      confirmIdentifier: "hotkeys.keyword.sheet.save", cancel: onDone, confirm: save) {
            TypefluxForm {
                TypefluxFormSection(L("hotkeys.keyword.sheet.hint")) {
                    TypefluxSettingsRow(L("hotkeys.keyword.sheet.keyword")) { keywordPicker }
                    TypefluxSettingsRow(L("hotkeys.keyword.sheet.shortcut")) { shortcutField }
                }
                Section {
                    TypefluxSwitch(L("ask.settings.keywords.enabled"), isOn: $draft.hotkey.enabled)
                    if !draft.isNew {
                        TypefluxButton(L("hotkeys.keyword.delete"), kind: .destructive) { confirmsDeletion = true }
                    }
                }
            }.frame(height: 300)
        }.frame(width: 480)
            .onDisappear { recorder.stop() }
            .alert(L("hotkeys.keyword.delete"), isPresented: $confirmsDeletion) {
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("hotkeys.keyword.delete"), role: .destructive) {
                    model.delete(draft.hotkey.id)
                    onDone()
                }
            } message: { Text(draft.hotkey.keyword) }
    }

    private var keywordPicker: some View {
        TypefluxPopup(L("hotkeys.keyword.sheet.keyword"), selection: Binding(
            get: { selected?.id ?? "" },
            set: { id in
                if let option = model.options.first(where: { $0.id == id }) {
                    draft.select(option)
                }
            }
        ), borderless: true) {
            if selected == nil {
                Text(draft.hotkey.keyword.isEmpty ? L("hotkeys.keyword.sheet.choose")
                    : L("hotkeys.keyword.status.missing")).tag("")
            }
            ForEach(model.options) { option in
                Text(optionLabel(option)).tag(option.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(L("hotkeys.keyword.sheet.keyword"))
        .accessibilityIdentifier("hotkeys.keyword.sheet.keyword")
    }

    private func optionLabel(_ option: KeywordHotkeyOption) -> String {
        let label = "\(option.keyword.keyword) · \(option.name)"
        return option.keyword.enabled ? label : label + " (" + L("hotkeys.keyword.sheet.keywordOff") + ")"
    }

    @ViewBuilder private var shortcutField: some View {
        HStack(spacing: 8) {
            TypefluxButton(kind: .borderless, action: toggleRecording) {
                HStack(spacing: 8) {
                    if draft.hotkey.binding == nil, !recorder.isRecording {
                        Image(systemName: "keyboard").foregroundStyle(TypefluxColor.secondaryLabel.color)
                        Text(L("hotkeys.keyword.sheet.record"))
                            .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                    } else {
                        HotkeyKeysView(binding: draft.hotkey.binding, isRecording: recorder.isRecording)
                    }
                    Spacer(minLength: 0)
                }
            }
            .help(L("hotkeys.recordHelp"))
            .accessibilityLabel(L("hotkeys.keyword.sheet.record"))
            .accessibilityValue(recorder.isRecording ? L("hotkeys.recording")
                : draft.hotkey.binding.map(HotkeyFormat.display) ?? L("settings.shortcuts.none"))
            .accessibilityIdentifier("hotkeys.keyword.sheet.record")
            if draft.hotkey.binding != nil, !recorder.isRecording {
                TypefluxIconButton(L("settings.shortcuts.unset"), systemImage: "xmark.circle.fill") {
                    draft.hotkey.binding = nil
                }
            }
        }
        if recorder.isRecording {
            hint(L("hotkeys.recording.hint"))
        } else if let result, let problem = result.problem {
            Text(model.message(for: problem)).font(.subheadline).foregroundStyle(TypefluxColor.danger.color)
            if draft.keywordOwner(in: result) != nil {
                TypefluxCheckbox(L("hotkeys.keyword.sheet.takeKeys"), isOn: $draft.takesKeys)
                    .accessibilityIdentifier("hotkeys.keyword.sheet.takeKeys")
            }
        } else if result?.overridesSystemShortcut == true {
            Text(L("hotkeys.conflict.system")).font(.subheadline).foregroundStyle(TypefluxColor.warning.color)
        } else {
            hint(L("hotkeys.keyword.sheet.shortcutHint"))
        }
    }

    private func save() {
        model.save(draft.hotkey, takingFrom: draft.takesKeys ? draft.keywordOwner(in: result) : nil)
        onDone()
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            return
        }
        recorder.start { binding in draft.record(binding) }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(TypefluxColor.tertiaryLabel.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
