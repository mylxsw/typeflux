import SwiftUI

/// General preferences keep the existing persistence and system action paths.
struct GeneralSettingsView: View {
    @ObservedObject var viewModel: StudioViewModel
    @ObservedObject private var localization = AppLocalization.shared
    let onManageMemory: () -> Void
    @State private var confirmsScreenshotReset = false
    @State private var confirmsLauncherReset = false

    var body: some View {
        TypefluxForm {
            TypefluxFormSection(AppSettingsPane.general.title) {
                switchRow("settings.launchAtLogin", value: viewModel.launchAtLogin, set: viewModel.setLaunchAtLogin)
            }
            if viewModel.isTextTransformationAvailable {
                TypefluxFormSection(L("settings.output.title")) {
                    switchRow("settings.output.opencc", value: viewModel.textTransformationEnabled,
                              set: viewModel.setTextTransformationEnabled)
                    if viewModel.textTransformationEnabled {
                        TypefluxSettingsRow(L("settings.output.opencc.config.title")) {
                            TypefluxPopup(L("settings.output.opencc.config.title"), selection: Binding(
                                get: { viewModel.textTransformationRule }, set: viewModel.setTextTransformationRule
                            ), borderless: true) {
                                ForEach(["s2twp", "s2tw", "s2hk", "t2s"], id: \.self) { rule in
                                    Text(L("settings.output.opencc.config." + rule)).tag(rule)
                                }
                            }
                        }
                    }
                }
            }
            TypefluxFormSection(L("settings.inputAndCapture.title")) {
                switchRow("settings.shortcuts.quickInput", value: viewModel.quickInputEnabled,
                          set: viewModel.setQuickInputEnabled, identifier: "settings.quickInput")
                launcherPosition
                screenshotLocation
            }
            TypefluxFormSection(L("settings.audio")) {
                TypefluxSettingsRow(L("settings.microphone.title"), description: L("settings.microphone.subtitle")) {
                    HStack {
                        TypefluxPopup(L("settings.microphone.title"), selection: Binding(
                            get: { viewModel.preferredMicrophoneID }, set: viewModel.setPreferredMicrophoneID
                        ), borderless: true) {
                            Text(L("settings.microphone.automatic")).tag(AudioDeviceManager.automaticDeviceID)
                            ForEach(viewModel.availableMicrophones, id: \.id) { microphone in
                                Text(microphone.name).tag(microphone.id)
                            }
                        }
                        TypefluxIconButton(L("common.refresh"), systemImage: "arrow.clockwise") {
                            viewModel.refreshAvailableMicrophones()
                        }
                    }
                }
                switchRow("settings.instantVoiceInput", value: viewModel.instantVoiceInputEnabled,
                          set: viewModel.setInstantVoiceInputEnabled)
                switchRow("settings.mouseVoice", value: viewModel.mouseVoiceInputEnabled,
                          set: viewModel.setMouseVoiceInputEnabled)
                if viewModel.mouseVoiceInputEnabled {
                    TypefluxSettingsRow(L("settings.mouseVoice.activation.title"),
                                        description: L("settings.mouseVoice.activation.subtitle")) {
                        TypefluxPopup(L("settings.mouseVoice.activation.title"), selection: Binding(
                            get: { viewModel.mouseVoiceActivationStyle }, set: viewModel.setMouseVoiceActivationStyle
                        ), borderless: true) {
                            ForEach(MouseVoiceActivationStyle.allCases, id: \.self) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                    }
                }
                switchRow("settings.mute", value: viewModel.muteSystemOutputDuringRecording,
                          set: viewModel.setMuteSystemOutputDuringRecording)
            }
            TypefluxFormSection(L("settings.permissions")) {
                TypefluxSettingsRow(L("settings.permissionStatus.title"),
                                    description: L("settings.permissionStatus.subtitle")) {
                    TypefluxButton(viewModel.isRefreshingPermissions ? L("common.refreshing") : L("common.refresh")) {
                        viewModel.refreshPermissionRowsWithFeedback()
                    }
                    .disabled(viewModel.isRefreshingPermissions)
                }
                ForEach(viewModel.permissionRows) { permission in
                    TypefluxSettingsRow(permission.title, description: permission.summary + "\n" + permission.detail) {
                        HStack {
                            TypefluxStatus(permission.badgeText, tone: permission.isGranted ? .success : .warning)
                            TypefluxButton(permission.actionTitle, kind: permission.isGranted ? .regular : .primary) {
                                viewModel.requestPermission(permission.id)
                            }
                        }
                    }
                }
            }
            TypefluxFormSection(L("settings.other")) {
                switchRow("settings.advanced.autoVocabulary", value: viewModel.automaticVocabularyCollectionEnabled,
                          set: viewModel.setAutomaticVocabularyCollectionEnabled)
                switchRow("settings.advanced.recentInputMemory", value: viewModel.recentInputMemoryEnabled,
                          set: viewModel.setRecentInputMemoryEnabled)
                    .onAppear { viewModel.refreshRecentInputMemoryApplications() }
                switchRow("settings.advanced.globalSoul", value: viewModel.globalSoulMemoryEnabled,
                          set: viewModel.setGlobalSoulMemoryEnabled)
                TypefluxButton(L("settings.advanced.recentInputMemory.manage"), action: onManageMemory)
                switchRow("settings.advanced.autoUpdate", value: viewModel.autoUpdateEnabled,
                          set: viewModel.setAutoUpdateEnabled)
                switchRow("settings.analyticsSharing", value: viewModel.analyticsSharingEnabled,
                          set: viewModel.setAnalyticsSharingEnabled)
            }
        }
        .alert(L("settings.shortcuts.screenshot.saveLocation.reset"), isPresented: $confirmsScreenshotReset) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.reset"), role: .destructive) { viewModel.resetScreenshotSaveDirectory() }
        } message: {
            Text(SettingsStore.defaultScreenshotSaveDirectory.path)
        }
        .alert(L("settings.shortcuts.launcherPosition.reset"), isPresented: $confirmsLauncherReset) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.reset"), role: .destructive) { viewModel.resetAskLauncherPositions() }
        } message: {
            Text(L("settings.shortcuts.launcherPosition.center.subtitle"))
        }
    }

    private func switchRow(_ key: String, value: Bool, set: @escaping (Bool) -> Void,
                           identifier: String? = nil) -> some View {
        TypefluxSettingsRow(L(key + ".title"), description: L(key + ".subtitle")) {
            TypefluxSwitch(L(key + ".title"), isOn: Binding(get: { value }, set: set), labelsHidden: true)
                .accessibilityIdentifier(identifier ?? key)
        }
    }

    private var screenshotLocation: some View {
        TypefluxSettingsRow(L("settings.shortcuts.screenshot.saveLocation.title"),
                            description: viewModel.screenshotSaveDirectory.path) {
            HStack {
                if viewModel.screenshotSaveDirectory.standardizedFileURL
                    != SettingsStore.defaultScreenshotSaveDirectory.standardizedFileURL {
                    TypefluxButton(L("settings.shortcuts.screenshot.saveLocation.reset"), kind: .destructive) {
                        confirmsScreenshotReset = true
                    }
                }
                TypefluxButton(L("settings.shortcuts.screenshot.saveLocation.choose")) {
                    viewModel.chooseScreenshotSaveDirectory()
                }
            }
        }
    }

    private var launcherPosition: some View {
        TypefluxSettingsRow(L("settings.shortcuts.launcherPosition.title"), description: L(
            viewModel.askLauncherPosition == .center ? "settings.shortcuts.launcherPosition.center.subtitle"
                : "settings.shortcuts.launcherPosition.last.subtitle"
        )) {
            HStack {
                if viewModel.askLauncherPosition == .lastPosition {
                    TypefluxButton(L("settings.shortcuts.launcherPosition.reset"), kind: .destructive) {
                        confirmsLauncherReset = true
                    }
                    .disabled(!viewModel.hasRememberedLauncherPositions)
                }
                TypefluxSegmentedControl(L("settings.shortcuts.launcherPosition.title"), selection: Binding(
                    get: { viewModel.askLauncherPosition }, set: viewModel.setAskLauncherPosition
                )) {
                    Text(L("settings.shortcuts.launcherPosition.center")).tag(AskLauncherPosition.center)
                    Text(L("settings.shortcuts.launcherPosition.last")).tag(AskLauncherPosition.lastPosition)
                }
            }
        }
        .onAppear { viewModel.refreshAskLauncherPositions() }
    }
}
