import SwiftUI

/// Launcher settings panes: results shown right in the launcher, keywords, translation and workflows.
/// These run from the launcher without the Agent, so they live on their own page.
struct LauncherSettingsView: View {
    let settings: SettingsStore
    var pane: LauncherSettingsPane = .basics
    var workflows: AskWorkflowStore = .shared

    @State var quickCalculatorEnabled = true

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
            case .workflows:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title)
                ModelSurface {
                    AskWorkflowSettingsView(store: workflows, settings: settings)
                }
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private var basicsPane: some View {
        AgentPaneHeader(symbol: pane.symbol, title: pane.title)
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "plus.forwardslash.minus", title: L("ask.settings.quick.calculator.title")) {
                    Toggle("", isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.calculator.title"))
                }
            }
        }
    }

    func reload() {
        quickCalculatorEnabled = settings.askQuickCalculatorEnabled
    }

    func setQuickCalculator(_ enabled: Bool) {
        quickCalculatorEnabled = enabled
        settings.askQuickCalculatorEnabled = enabled
    }
}
