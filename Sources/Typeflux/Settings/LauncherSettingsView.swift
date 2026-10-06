import SwiftUI

/// Launcher settings panes: results shown right in the launcher, keywords and workflows.
/// These run from the launcher without the Agent, so they live on their own page.
struct LauncherSettingsView: View {
    let settings: SettingsStore
    var pane: LauncherSettingsPane = .basics
    var workflows: AskWorkflowStore = .shared

    @State var quickCalculatorEnabled = true
    @State var quickAppsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch pane {
            case .basics:
                basicsPane
            case .keywords:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title, subtitle: L("ask.settings.plugins.footnote"))
                AskLauncherPluginSettingsView(settings: settings, workflows: workflows)
            case .workflows:
                AgentPaneHeader(symbol: pane.symbol, title: pane.title, subtitle: L("ask.workflow.footnote"))
                ModelSurface {
                    AskWorkflowSettingsView(store: workflows, settings: settings)
                }
            }
        }
        .onAppear(perform: reload)
    }

    @ViewBuilder private var basicsPane: some View {
        AgentPaneHeader(symbol: pane.symbol, title: pane.title, subtitle: L("launcher.basics.subtitle"))
        ModelSurface {
            VStack(alignment: .leading, spacing: 0) {
                AgentSettingsRow(icon: "plus.forwardslash.minus", title: L("ask.settings.quick.calculator.title"),
                                 subtitle: L("ask.settings.quick.calculator.subtitle"), subtitleLineLimit: nil) {
                    Toggle("", isOn: Binding(get: { quickCalculatorEnabled }, set: setQuickCalculator))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.calculator.title"))
                }
                ModelRowDivider(leading: 66)
                AgentSettingsRow(icon: "square.grid.2x2", title: L("ask.settings.quick.apps.title"),
                                 subtitle: L("ask.settings.quick.apps.subtitle"), subtitleLineLimit: nil) {
                    Toggle("", isOn: Binding(get: { quickAppsEnabled }, set: setQuickApps))
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel(L("ask.settings.quick.apps.title"))
                }
            }
        }
    }

    func reload() {
        quickCalculatorEnabled = settings.askQuickCalculatorEnabled
        quickAppsEnabled = settings.askQuickAppSearchEnabled
    }

    func setQuickCalculator(_ enabled: Bool) {
        quickCalculatorEnabled = enabled
        settings.askQuickCalculatorEnabled = enabled
    }

    func setQuickApps(_ enabled: Bool) {
        quickAppsEnabled = enabled
        settings.askQuickAppSearchEnabled = enabled
    }
}
