import SwiftUI

/// Edits the same global binding shown on the Shortcuts page, next to its feature.
@MainActor
struct FeatureTriggerSettingsView: View {
    enum Feature {
        case launcher, chat

        var target: HotkeyTarget {
            switch self {
            case .launcher: .builtIn(.ask)
            case .chat: .action(.openChat)
            }
        }

        var identifier: String {
            switch self {
            case .launcher: "launcher.settings.trigger"
            case .chat: "agent.settings.trigger"
            }
        }
    }

    let feature: Feature
    @StateObject private var model: HotkeySettingsModel
    @StateObject private var recorder = HotkeyRecorder()
    @State private var isRecording = false
    @State private var notice: String?

    init(settings: SettingsStore, feature: Feature) {
        self.feature = feature
        _model = StateObject(wrappedValue: HotkeySettingsModel(settingsStore: settings, workflows: .shared))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TFFormSection {
                TFFormRow(title: L("settings.trigger.title"), detail: model.row(for: feature.target)?.subtitle,
                          icon: "keyboard") {
                    Button(action: toggleRecording) {
                        HotkeyKeysView(binding: model.row(for: feature.target)?.binding, isRecording: isRecording)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L(isRecording ? "settings.shortcuts.recordingGeneric" : "hotkeys.recordHelp"))
                    .accessibilityLabel(L("hotkeys.recordAccessibility", model.row(for: feature.target)?.title ?? ""))
                    .accessibilityValue(isRecording ? L("hotkeys.recording")
                        : model.row(for: feature.target)?.binding.map(HotkeyFormat.display) ?? L("settings.shortcuts.none"))
                    .accessibilityIdentifier(feature.identifier)
                    TFButton(title: L("settings.shortcuts.unset"), systemImage: "xmark", kind: .plain, size: .small,
                             iconOnly: true) {
                        stopRecording()
                        notice = nil
                        switch feature {
                        case .launcher: model.settingsStore.setHotkey(nil, for: BuiltInHotkey.ask)
                        case .chat: model.unsetHotkey(for: .openChat)
                        }
                    }
                    .disabled(model.row(for: feature.target)?.binding == nil)
                    .accessibilityIdentifier(feature.identifier + ".unset")
                }
            }
            if let notice {
                TFFieldMessage(text: notice, tone: .warning).padding(.horizontal, 4)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
            return
        }
        isRecording = true
        notice = nil
        recorder.start { binding in
            isRecording = false
            switch feature {
            case .launcher: notice = model.setHotkey(binding, for: BuiltInHotkey.ask)
            case .chat: notice = model.setHotkey(binding, for: AppHotkeyAction.openChat)
            }
            if notice == nil, HotkeyConflictChecker.isCommonSystemShortcut(binding)
                || SystemSymbolicHotkeys.current.contains(binding) {
                notice = L("hotkeys.conflict.system")
            }
        }
    }

    private func stopRecording() {
        recorder.stop()
        isRecording = false
    }
}
