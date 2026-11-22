import SwiftUI

struct AskTurnConclusion<Content: View>: View {
    let message: AskMessage
    let usage: AskUsageTotals?
    let canRegenerate: Bool
    let savedToNotes: Bool
    let onReference: (AskReference) -> Void
    let onRegenerate: () -> Void
    let onSaveNote: (() -> Void)?
    let onUsage: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 16) { content() }
            turnActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// The row keeps its height while hidden, so hovering never reflows the
    /// transcript under the pointer. Opacity (not a conditional view) also keeps
    /// the actions reachable by VoiceOver and the keyboard at all times.
    private var turnActions: some View {
        HStack(spacing: 2) {
            AskIconGhostButton(label: copied ? L("ask.copied") : L("ask.copy"),
                               systemImage: copied ? "checkmark" : "doc.on.doc", active: copied) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .accessibilityIdentifier("ask.answer.copy." + message.id)
            // An interrupted answer already offers this on its tag.
            if canRegenerate, message.isError != true {
                AskIconGhostButton(label: L("ask.regenerate"), systemImage: "arrow.clockwise", action: onRegenerate)
            }
            AskIconGhostButton(label: L("ask.quote"), systemImage: "text.quote") {
                onReference(AskReference(messageId: message.id, text: message.text, question: ""))
            }
            if let onSaveNote {
                AskIconGhostButton(label: L(savedToNotes ? "ask.notes.savedAnswer" : "ask.notes.saveAnswer"),
                                   systemImage: savedToNotes ? "note.text" : "note.text.badge.plus",
                                   active: savedToNotes) { onSaveNote() }
                    .accessibilityIdentifier("ask.message.saveNote")
            }
            AskIconGhostButton(label: usageHelp, systemImage: "chart.bar.xaxis", action: onUsage)
            .accessibilityLabel(L("ask.usage.title"))
            .accessibilityValue(usageLabel)
        }
        .opacity(hovering || copied || savedToNotes ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var usageLabel: String {
        guard let usage else { return L("ask.usage.title") }
        if usage.calls > 0, usage.external == usage.calls { return usage.tokenText(usage.totalTokens) + " tokens" }
        return usage.creditsText + " credits"
    }

    private var usageHelp: String {
        guard usage != nil else { return L("ask.usage.title") }
        return L("ask.usage.title") + " · " + usageLabel
    }
}
