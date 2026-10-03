import SwiftUI

/// A quiet, named entry point for inspecting the metadata sent with a question.
/// It remains usable when screenshots are disabled or unsupported by the model.
struct AskSourceContextButton: View {
    @Binding var draft: AskDraft
    var restored = false
    var capturing = false
    var warning: String?
    var refresh: (() -> Void)?
    /// A narrow composer moves its existing controls into this panel.
    var controls: AnyView?
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 4) {
                Text(L("ask.context.details")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(StudioTheme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: AskMetrics.composerControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("ask.context.details")
        .accessibilityLabel(L("ask.context.details"))
        .popover(isPresented: $presented, arrowEdge: .top) {
            AskSourceContextDetails(draft: $draft, restored: restored, capturing: capturing,
                                    warning: warning, refresh: refresh, controls: controls)
        }
    }
}

/// Metadata, selection provenance, and screenshot scope are separate facts.
struct AskSourceContextDetails: View {
    @Binding var draft: AskDraft
    var restored = false
    var capturing = false
    var warning: String?
    var refresh: (() -> Void)?
    var controls: AnyView?

    private var source: (app: String, window: String?)? {
        guard let value = draft.source,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AskContextChips.sourceParts(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("ask.context.details"))
                .font(.system(size: 13, weight: .semibold))
            if let source {
                sourceDetails(app: source.app, window: source.window)
            } else {
                Text(L("ask.context.source.none"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            Divider()
            Label(L(draft.includeScreenshot && draft.screenshot != nil
                    ? "ask.context.screen.included" : "ask.context.screen.excluded"), systemImage: "display")
                .font(.system(size: 12))
            Text(L("ask.context.screen.scope"))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            if let selection = draft.sentSelection, !selection.isEmpty {
                Label(L("ask.selection.lines", AskPresentation.lineCount(selection)), systemImage: "text.alignleft")
                    .font(.system(size: 12))
                if let source {
                    Text(L("ask.context.selection.source", source.app))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                }
                Text(AskContextChips.selectionPreview(selection))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(3)
            } else {
                Label(L("ask.context.selection.excluded"), systemImage: "text.alignleft")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            if let controls {
                controls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ask.context.controls")
            }
            if let refresh {
                Divider()
                HStack(spacing: 8) {
                    Button(L("ask.context.refresh"), action: refresh)
                        .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                        .accessibilityIdentifier("ask.context.refresh")
                        .disabled(capturing)
                    if capturing { ProgressView().controlSize(.small) }
                }
                Text(L("ask.context.refresh.hint"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                    .accessibilityIdentifier("ask.context.refresh.warning")
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 320)
    }

    private func sourceDetails(app: String, window: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(restored ? "ask.context.source.draft" : "ask.context.source"))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            HStack(spacing: 6) {
                if let bundle = draft.sourceBundleID, let image = AskContextChips.appIcon(bundle) {
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(app).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            if let window {
                Text(window).font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                    .lineLimit(3).help(window)
            }
            Text(L(draft.sourceOff == true ? "ask.context.source.excluded" : "ask.context.source.included"))
                .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            let key = draft.sourceOff == true ? "ask.context.source.restore" : "ask.context.source.remove"
            Button(L(key)) { draft.sourceOff = draft.sourceOff == true ? nil : true }
                .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                .accessibilityIdentifier(key)
        }
    }
}
