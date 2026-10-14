import Carbon.HIToolbox
import SwiftUI

/// Launcher settings panes: general preferences, results, keywords, translation, the
/// clipboard and workflows. These run from the launcher without the Agent, so they live on their own page.
@MainActor
struct LauncherSettingsView: View {
    let settings: SettingsStore
    var pane: LauncherSettingsPane = .basics
    var workflows: AskWorkflowStore = .shared
    /// The clipboard history whose space the clipboard pane shows; `nil` hides that section.
    var clipboardHistory: ClipboardHistoryStore?
    /// Opens the shortcut settings from the clipboard pane.
    var onEditShortcut: () -> Void = {}
    var inputSources: any AskLauncherInputSourceListing = SystemAskLauncherInputSourceSelector()

    @State var inputSourceID = ""
    @State var availableInputSources: [AskLauncherInputSource] = []
    @State var quickCalculatorEnabled = true
    @State var quickNumberConversionsEnabled = true
    @State var inputHistoryEnabled = true
    @State var inputHistoryLimit = 100
    @State private var confirmingClearInputHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch pane {
            case .basics:
                basicsPane
            case .search:
                LauncherSearchSettingsView(settings: settings)
            case .keywords:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title)
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows)
            case .translation:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title)
                AskTranslationSettingsView(settings: settings)
            case .clipboard:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title)
                ClipboardSettingsView(settings: settings, history: clipboardHistory, onEditShortcut: onEditShortcut)
            case .workflows:
                AskWorkflowSettingsView(store: workflows, settings: settings)
            }
        }
        .onAppear(perform: reload)
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        )) { _ in reloadInputSources() }
        .alert(L("ask.inputHistory.clear"), isPresented: $confirmingClearInputHistory) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("ask.inputHistory.deleteAll"), role: .destructive) { settings.clearLauncherInputHistory() }
        } message: { Text(L("ask.inputHistory.clear.detail")) }
    }

    @ViewBuilder private var basicsPane: some View {
        AgentPaneHeader(symbol: pane.symbol, title: pane.title)
        ModelSurface {
            AgentSettingsRow(icon: "keyboard", title: L("launcher.inputSource.title"),
                             subtitle: L("launcher.inputSource.detail"), subtitleLineLimit: nil) {
                SettingsMenuPicker(title: L("launcher.inputSource.title"), options: inputSourceOptions,
                                   selection: Binding(get: { inputSourceID }, set: setInputSource))
                    .frame(width: 200)
                    .accessibilityIdentifier("launcher.settings.inputSource")
            }
        }
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "plus.forwardslash.minus", title: L("ask.settings.quick.calculator.title")) {
                    Toggle("", isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.calculator.title"))
                }
                ModelRowDivider(leading: 56)
                AgentSettingsRow(icon: "number", title: L("ask.settings.quick.numberConversions.title")) {
                    Toggle("", isOn: Binding(get: { quickNumberConversionsEnabled }, set: setQuickNumberConversions))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.numberConversions.title"))
                        .accessibilityIdentifier("launcher.settings.numberConversions")
                }
            }
        }
        StudioCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "clock.arrow.circlepath", title: L("ask.inputHistory.remember")) {
                    Toggle("", isOn: Binding(get: { inputHistoryEnabled }, set: setInputHistoryEnabled))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.inputHistory.remember"))
                        .accessibilityIdentifier("launcher.settings.inputHistory")
                }
                ModelRowDivider(leading: 56)
                AgentSettingsRow(icon: "list.number", title: L("ask.inputHistory.limit")) {
                    Picker("", selection: Binding(get: { inputHistoryLimit }, set: setInputHistoryLimit)) {
                        ForEach([50, 100, 200], id: \.self) { Text(String($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 100)
                    .accessibilityLabel(L("ask.inputHistory.limit"))
                }
                ModelRowDivider(leading: 56)
                AgentSettingsRow(icon: "trash", title: L("ask.inputHistory.clear")) {
                    Button(L("common.clear")) { confirmingClearInputHistory = true }
                }
            }
        }
        Text(L("ask.inputHistory.privacy")).font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
    }

    func reload() {
        reloadInputSources()
        quickCalculatorEnabled = settings.askQuickCalculatorEnabled
        quickNumberConversionsEnabled = settings.askQuickNumberConversionsEnabled
        inputHistoryEnabled = settings.askLauncherInputHistoryEnabled
        inputHistoryLimit = settings.askLauncherInputHistoryLimit
    }

    func reloadInputSources() {
        inputSourceID = settings.askLauncherInputSourceID
        availableInputSources = inputSources.availableSources()
    }

    var inputSourceOptions: [(label: String, value: String)] {
        var options = [(label: L("launcher.inputSource.none"), value: "")]
        options += availableInputSources.map { (label: $0.name, value: $0.id) }
        if !inputSourceID.isEmpty, !availableInputSources.contains(where: { $0.id == inputSourceID }) {
            options.append((label: L("launcher.inputSource.unavailable"), value: inputSourceID))
        }
        return options
    }

    func setInputSource(_ sourceID: String) {
        inputSourceID = sourceID
        settings.askLauncherInputSourceID = sourceID
    }

    func setInputHistoryEnabled(_ enabled: Bool) {
        inputHistoryEnabled = enabled
        settings.askLauncherInputHistoryEnabled = enabled
    }

    func setInputHistoryLimit(_ limit: Int) {
        inputHistoryLimit = limit
        settings.askLauncherInputHistoryLimit = limit
    }

    func setQuickCalculator(_ enabled: Bool) {
        quickCalculatorEnabled = enabled
        settings.askQuickCalculatorEnabled = enabled
    }

    func setQuickNumberConversions(_ enabled: Bool) {
        quickNumberConversionsEnabled = enabled
        settings.askQuickNumberConversionsEnabled = enabled
    }
}
