import SwiftUI

/// Manual note capture shares the launcher's editor; the preview never performs writes.
struct AskNoteCaptureView: View {
    @ObservedObject var model: AskConversationModel
    @ObservedObject var viewport: AskLauncherViewport
    var chrome: CGFloat
    var available: CGFloat?
    var natural: CGFloat
    var onSubmit: () -> Void
    var onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("ask.noteCapture.local"), systemImage: "internaldrive")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let failure = model.noteCapture.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.danger)
                    .accessibilityIdentifier("ask.noteCapture.failure")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.noteCapture.hasContent {
                        Text(AskNoteCaptureState.title(for: model.noteCapture.body))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(model.noteCapture.body)
                            .font(.system(size: 13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let note = model.noteCapture.saved {
                        Label(L("ask.noteCapture.saved", note.title), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .accessibilityIdentifier("ask.noteCapture.saved")
                        Text(L("ask.noteCapture.continue")).font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        Text(L("ask.noteCapture.placeholder")).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                if model.noteCapture.saving {
                    ProgressView().controlSize(.small)
                    Text(L("ask.noteCapture.saving"))
                } else {
                    Button(L("ask.noteCapture.clear")) { model.clearNoteCapture() }
                        .disabled(!model.noteCapture.hasContent && model.noteCapture.saved == nil)
                        .accessibilityIdentifier("ask.noteCapture.clear")
                    if let note = model.noteCapture.saved {
                        Button(L("ask.notes.openNote")) { onOpen(note.id) }
                            .accessibilityIdentifier("ask.noteCapture.open")
                    }
                }
                Spacer(minLength: 0)
                Button(
                    L(model.noteCapture.failure == nil ? "ask.noteCapture.save" : "ask.noteCapture.retry"),
                    action: onSubmit
                )
                .disabled(!model.noteCapture.hasContent || model.noteCapture.saving)
                .accessibilityIdentifier("ask.noteCapture.save")
            }
            .font(.system(size: 12)).buttonStyle(.borderless)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(height: viewport.resultsHeight(chrome: chrome, available: available, natural: natural))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ask.noteCapture.panel")
    }
}
