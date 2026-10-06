import SwiftUI

/// The launcher's bottom bar after a workflow's actions ran:
/// "✓ Copied “100 USD = …” · ✓ Notification sent      ⌘Z to undo the copy".
struct AskWorkflowActionsSummaryView: View {
    var state: AskWorkflowActionsState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(state.outcomes.enumerated()), id: \.offset) { index, outcome in
                    if let text = Self.text(for: outcome) {
                        if index > 0 {
                            Text("·").foregroundStyle(StudioTheme.textTertiary)
                        }
                        Text(text).foregroundStyle(outcome.succeeded ? StudioTheme.success : StudioTheme.danger)
                            .lineLimit(1)
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if state.undone {
                Text(L("ask.workflow.action.copyUndone")).foregroundStyle(StudioTheme.textTertiary)
            } else if state.canUndo {
                Text(L("ask.workflow.action.undoHint")).foregroundStyle(StudioTheme.textTertiary)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.workflow.actions.summary")
    }

    /// One outcome as the bar says it; nil for steps that were not run.
    static func text(for outcome: AskWorkflowActionOutcome) -> String? {
        AskWorkflowActionRunner.summary([outcome]).nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
