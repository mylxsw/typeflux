import SwiftUI

/// A short confirmation that keeps Undo reachable when the footer is narrow.
struct AskCapturedContentFeedbackView: View {
    let feedback: AskCapturedContentFeedback
    var undo: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Text(feedback.text).lineLimit(1)
                    .foregroundStyle(TypefluxColor.secondaryLabel.color)
                if feedback.canUndo { undoButton }
            }
            .fixedSize()
            if feedback.canUndo {
                undoButton
            } else {
                Text(feedback.text).lineLimit(1).foregroundStyle(TypefluxColor.secondaryLabel.color)
            }
        }
        .font(.system(size: 11))
        .help(feedback.text)
    }

    private var undoButton: some View {
        Button(L("ask.context.undo"), action: undo)
            .buttonStyle(.plain)
            .fixedSize()
            .foregroundStyle(TypefluxColor.accent.color)
            .accessibilityIdentifier("ask.context.undo")
    }
}

/// Measured after wrapping, so the launcher grows with its actual content.
struct AskCapturedStripHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
