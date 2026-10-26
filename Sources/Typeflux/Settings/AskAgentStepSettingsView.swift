import SwiftUI

/// Agent → Overview: execution policy for new runs and optional reply limit.
struct AskAgentStepSettingsView: View {
    let settings: SettingsStore
    @State private var executionMode: AskExecutionMode = .continuous
    @State private var maxSteps = SettingsStore.defaultAskAgentMaxSteps

    private var options: [Int] {
        Array(Set(SettingsStore.askAgentMaxStepOptions + [maxSteps])).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            TFFormRow(title: L("ask.steps.mode"), detail: L("ask.steps.modeDetail"), icon: "repeat") {
                TFPopUpButton(title: L("ask.steps.mode"), options: [
                    TFOption(AskExecutionMode.continuous, L("ask.steps.continuous")),
                    TFOption(AskExecutionMode.bounded, L("ask.steps.bounded"))
                ], selection: $executionMode, width: TFMetrics.formControlWidth)
                    .accessibilityIdentifier("agent.settings.executionMode")
            }
            if executionMode == .bounded {
                TFFormRow(title: L("ask.steps.limit"), detail: L("ask.steps.detail"), icon: "list.number") {
                    TFPopUpButton(title: L("ask.steps.limit"), options: options.map { TFOption($0, String($0)) },
                                  selection: $maxSteps, width: TFMetrics.formControlWidth)
                        .accessibilityIdentifier("agent.settings.maxSteps")
                }
            }
        }
        .onAppear { maxSteps = settings.askAgentMaxSteps; executionMode = settings.askAgentExecutionMode }
        .onChange(of: maxSteps) { settings.askAgentMaxSteps = $0 }
        .onChange(of: executionMode) { settings.askAgentExecutionMode = $0 }
    }
}
