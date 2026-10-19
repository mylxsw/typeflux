import SwiftUI

/// Agent → Overview: maximum model replies allowed in a new run.
struct AskAgentStepSettingsView: View {
    let settings: SettingsStore
    @State private var maxSteps = SettingsStore.defaultAskAgentMaxSteps

    private var options: [Int] {
        Array(Set(SettingsStore.askAgentMaxStepOptions + [maxSteps])).sorted()
    }

    var body: some View {
        TFFormSection(title: L("ask.steps.section")) {
            TFFormRow(title: L("ask.steps.limit"), detail: L("ask.steps.detail"), icon: "list.number") {
                TFPopUpButton(title: L("ask.steps.limit"), options: options.map { TFOption($0, String($0)) },
                              selection: $maxSteps, width: TFMetrics.formControlWidth)
                    .accessibilityIdentifier("agent.settings.maxSteps")
            }
        }
        .onAppear { maxSteps = settings.askAgentMaxSteps }
        .onChange(of: maxSteps) { settings.askAgentMaxSteps = $0 }
    }
}
