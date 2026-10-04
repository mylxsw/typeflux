import SwiftUI

/// The same compact, keyboard-accessible action is used on the saved source
/// chip and its details. The tooltip describes its target and selection impact.
struct AskSourceRefreshButton: View {
    var help: String
    var disabled = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier("ask.context.refresh")
    }
}

/// Inspect only the app and window metadata represented by the source chip.
/// Selection and screenshot content have their own previews and removals.
struct AskSourceContextDetails: View {
    @Binding var draft: AskDraft
    var restored = false
    var capturing = false
    var warning: String?
    var refresh: (() -> Void)?
    var refreshHelp: String?
    var onRemove: (() -> Void)?

    private var source: (app: String, window: String?)? {
        guard let value = draft.source,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AskContextChips.sourceParts(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let bundle = draft.sourceBundleID, let image = AskContextChips.appIcon(bundle) {
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(L(restored ? "ask.context.source.draft" : "ask.context.source"))
                    .font(.system(size: 13, weight: .semibold))
            }
            if let source {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    metadataRow(L("ask.context.source.app"), value: source.app)
                    if let window = source.window {
                        metadataRow(L("ask.context.source.window"), value: window)
                    }
                }
                Text(L("ask.context.source.metadataOnly"))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                if draft.sourceOff == true {
                    Text(L("ask.context.source.excluded"))
                        .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
                }
            } else {
                Text(L("ask.context.source.none"))
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.textSecondary)
            }
            if source != nil || refresh != nil {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if let refresh {
                        AskSourceRefreshButton(help: refreshHelp ?? L("ask.context.refresh.hint"),
                                               disabled: capturing, action: refresh)
                    }
                    if source != nil {
                        let key = draft.sourceOff == true ? "ask.context.source.restore" : "ask.context.source.remove"
                        Button(L(key)) {
                            if draft.sourceOff == true {
                                draft.sourceOff = nil
                            } else if let onRemove {
                                onRemove()
                            } else {
                                draft.sourceOff = true
                            }
                        }
                        .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                        .accessibilityIdentifier(key)
                    }
                }
            }
            if let warning {
                Text(warning).font(.system(size: 11)).foregroundStyle(StudioTheme.warning)
                    .accessibilityIdentifier("ask.context.refresh.warning")
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 340)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(StudioTheme.textSecondary)
            Text(value).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
    }
}

/// The complete selected text is inspectable even after source metadata has
/// been removed. Its provenance describes capture, not the outgoing metadata.
struct AskSelectedTextDetails: View {
    var text: String
    var source: String?
    var restored = false
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("ask.selection.lines", AskPresentation.lineCount(text)))
                .font(.system(size: 13, weight: .semibold))
            if let source, !source.isEmpty {
                Text(L("ask.context.selection.source", source)
                     + (restored ? " · " + L("ask.context.source.previous") : ""))
                    .font(.system(size: 11)).foregroundStyle(StudioTheme.textSecondary)
            }
            ScrollView {
                Text(text).font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 240)
            .background(AskTheme.hoverFill, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(L("ask.selection.remove"), action: onRemove)
                    .buttonStyle(AskCapsuleButtonStyle(kind: .secondary))
                    .accessibilityIdentifier("ask.context.selection.remove")
            }
        }
        .foregroundStyle(StudioTheme.textPrimary)
        .padding(16)
        .frame(width: 360)
    }
}
