import SwiftUI

/// Launcher settings panes: results shown right in the launcher, keywords, translation, the
/// clipboard and workflows. These run from the launcher without the Agent, so they live on their own page.
struct LauncherSettingsView: View {
    let settings: SettingsStore
    var pane: LauncherSettingsPane = .basics
    var searchQuery: Binding<String> = .constant("")
    var workflows: AskWorkflowStore = .shared
    /// The clipboard history whose space the clipboard pane shows; `nil` hides that section.
    var clipboardHistory: ClipboardHistoryStore?
    /// Opens the shortcut settings from the clipboard pane.
    var onEditShortcut: () -> Void = {}

    @State var quickCalculatorEnabled = true
    @State var quickNumberConversionsEnabled = true
    @State var inputHistoryEnabled = true
    @State var inputHistoryLimit = 100
    @State private var confirmingClearInputHistory = false

    var body: some View {
        Group {
            switch pane {
            case .basics:
                basicsPane
            case .search:
                LauncherSearchSettingsView(settings: settings)
            case .keywords:
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows, query: searchQuery)
            case .translation:
                AskTranslationSettingsView(settings: settings)
            case .clipboard:
                ClipboardSettingsView(settings: settings, history: clipboardHistory, onEditShortcut: onEditShortcut)
            case .workflows:
                AskWorkflowSettingsView(store: workflows, settings: settings, searchQuery: searchQuery.wrappedValue)
            }
        }
        .onAppear(perform: reload)
        .alert(L("ask.inputHistory.clear"), isPresented: $confirmingClearInputHistory) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("ask.inputHistory.deleteAll"), role: .destructive) { settings.clearLauncherInputHistory() }
        } message: { Text(L("ask.inputHistory.clear.detail")) }
    }

    private var basicsPane: some View {
        TypefluxForm {
            Section {
                AgentSettingsRow(icon: "plus.forwardslash.minus", title: L("ask.settings.quick.calculator.title")) {
                    TypefluxSwitch(L("ask.settings.quick.calculator.title"),
                                   isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator),
                                   labelsHidden: true)
                }
                AgentSettingsRow(icon: "number", title: L("ask.settings.quick.numberConversions.title")) {
                    TypefluxSwitch(L("ask.settings.quick.numberConversions.title"),
                                   isOn: Binding(get: { quickNumberConversionsEnabled },
                                                 set: setQuickNumberConversions), labelsHidden: true)
                        .accessibilityIdentifier("launcher.settings.numberConversions")
                }
            }
            Section {
                AgentSettingsRow(icon: "clock.arrow.circlepath", title: L("ask.inputHistory.remember")) {
                    TypefluxSwitch(L("ask.inputHistory.remember"),
                                   isOn: Binding(get: { inputHistoryEnabled }, set: setInputHistoryEnabled),
                                   labelsHidden: true)
                        .accessibilityIdentifier("launcher.settings.inputHistory")
                }
                AgentSettingsRow(icon: "list.number", title: L("ask.inputHistory.limit")) {
                    TypefluxPopup(L("ask.inputHistory.limit"),
                                  selection: Binding(get: { inputHistoryLimit }, set: setInputHistoryLimit),
                                  borderless: true) {
                        ForEach([50, 100, 200], id: \.self) { Text(String($0)).tag($0) }
                    }.frame(width: 100)
                }
                AgentSettingsRow(icon: "trash", title: L("ask.inputHistory.clear")) {
                    Button(L("common.clear")) { confirmingClearInputHistory = true }
                }
            } footer: { Text(L("ask.inputHistory.privacy")).font(.subheadline) }
        }
    }

    func reload() {
        quickCalculatorEnabled = settings.askQuickCalculatorEnabled
        quickNumberConversionsEnabled = settings.askQuickNumberConversionsEnabled
        inputHistoryEnabled = settings.askLauncherInputHistoryEnabled
        inputHistoryLimit = settings.askLauncherInputHistoryLimit
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
