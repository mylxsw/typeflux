import AppKit
import SwiftUI

struct TerminalKeywordSettingsView: View {
    @Binding var runner: TerminalRunner
    @Binding var terminal: TerminalApplication
    @Binding var settings: TerminalRunSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            heading("run")
            row("terminal.settings.runner") {
                Picker(L("terminal.settings.runner"), selection: $runner) {
                    Text(L("terminal.launcher.destination")).tag(TerminalRunner.launcher)
                    Text(L("terminal.launcher.windowDestination")).tag(TerminalRunner.window)
                    Text(L("terminal.runner.external")).tag(TerminalRunner.external)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("terminal.runner.settings.runner")
            }
            toggle("terminal.settings.confirm", value: $settings.confirmsRisky)
            heading("sessions")
            row("terminal.settings.start") {
                choices("terminal.settings.start", value: $settings.startDirectory)
            }
            if settings.startDirectory == .fixed {
                row("terminal.runner.settings.directory") {
                    HStack(spacing: 8) {
                        TextField(TerminalRunSettings.defaultDirectory, text: $settings.directory)
                            .textFieldStyle(ModelFieldStyle())
                            .accessibilityIdentifier("terminal.runner.settings.directory")
                        Button(L("terminal.runner.settings.chooseDirectory"), action: chooseDirectory)
                            .buttonStyle(ModelActionStyle())
                    }
                }
            }
            row("terminal.runner.settings.shell") {
                Picker(L("terminal.runner.settings.shell"), selection: $settings.shell) {
                    Text(L("terminal.runner.shell.interactive")).tag(TerminalShellProfile.interactive)
                    Text(L("terminal.runner.shell.login")).tag(TerminalShellProfile.login)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("terminal.runner.settings.shell")
            }
            row("terminal.settings.idle") {
                choices("terminal.settings.idle", value: $settings.idle)
            }
            toggle("terminal.settings.notify", value: $settings.notifies)
            row("terminal.settings.insert") {
                choices("terminal.settings.insert", value: $settings.insert)
            }
            heading("window")
            row("terminal.settings.finish") {
                Picker(L("terminal.settings.finish"), selection: $settings.finish) {
                    Text(L("terminal.runner.finish.auto")).tag(TerminalFinishPolicy.auto)
                    Text(L("terminal.runner.finish.keep")).tag(TerminalFinishPolicy.keep)
                    Text(L("terminal.runner.finish.close")).tag(TerminalFinishPolicy.close)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("terminal.runner.settings.finish")
            }
            toggle("terminal.runner.settings.pinned", value: $settings.pinned)
            row("terminal.settings.external") {
                Picker(L("terminal.settings.external"), selection: $terminal) {
                    ForEach(TerminalApplication.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("terminal.command.application")
            }
        }
    }

    private func heading(_ group: String) -> some View {
        Text(L("terminal.settings.group." + group))
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(StudioTheme.textPrimary)
            .padding(.top, 4)
    }

    private func row<Control: View>(_ key: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(L(key)).font(.system(size: 12.5)).foregroundStyle(StudioTheme.textSecondary)
            Spacer(minLength: 4)
            control()
        }
    }

    private func toggle(_ key: String, value: Binding<Bool>) -> some View {
        row(key) {
            Toggle(L(key), isOn: value)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityIdentifier(key)
        }
    }

    private func choices<Value: CaseIterable & RawRepresentable & Hashable>(
        _ key: String, value: Binding<Value>
    ) -> some View where Value.RawValue == String {
        Picker(L(key), selection: value) {
            ForEach(Array(Value.allCases), id: \.self) { option in
                Text(L(key + "." + option.rawValue)).tag(option)
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .accessibilityIdentifier(key)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let directory = TerminalRunSettings.expand(settings.directory, home: NSHomeDirectory())
        panel.directoryURL = URL(fileURLWithPath: directory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.directory = TerminalRunSettings.abbreviate(url.path, home: NSHomeDirectory())
    }
}
