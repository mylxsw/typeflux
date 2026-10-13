import SwiftUI

/// Feedback stays beside the changed content and its undo action.
struct AgentUndoBanner: View {
    let message: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    var duration: Duration = .seconds(5)

    var body: some View {
        HStack(spacing: 12) {
            Label(message, systemImage: "checkmark.circle").font(.callout)
            Spacer(minLength: 8)
            Button(L("agent.undo"), action: onUndo).buttonStyle(.bordered)
        }
        .task(id: message) {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled {
                onDismiss()
            }
        }
    }
}
