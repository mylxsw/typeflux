import SwiftUI

/// The more menu in the clipboard panel's hint bar.
struct ClipboardPanelToolbar: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        Button {
            model.onShowActions?()
        } label: {
            Text("⌘K " + L("clipboard.toolbar.more"))
                .font(.footnote)
                .foregroundStyle(TypefluxColor.secondaryLabel.color)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .help(L("clipboard.toolbar.more"))
        .accessibilityLabel(L("clipboard.toolbar.more"))
        .accessibilityIdentifier("clipboard.more")
    }
}

/// The app filter in the hint bar, with a button to show every app again.
struct ClipboardAppFilterChip: View {
    let app: ClipboardAppFilter
    let onClear: () -> Void

    var body: some View {
        TypefluxToken(app.name, removeLabel: L("clipboard.filter.clear"), onRemove: onClear)
            .frame(maxWidth: 220, alignment: .leading)
    }
}

/// The footer's pause notice. Clicking resumes recording.
struct ClipboardPausedChip: View {
    let onResume: () -> Void

    var body: some View {
        TypefluxToken(L("clipboard.footer.paused"), removeLabel: "", systemImage: "pause.circle",
                      action: onResume)
            .padding(.leading, 8)
            .help(L("clipboard.toolbar.resume"))
    }
}

/// `⌘E`: edit the text, then paste it with `⌘↩`. The stored entry is unchanged.
struct ClipboardEditBeforePaste: View {
    @ObservedObject var model: ClipboardPanelModel
    @FocusState private var focused: Bool
    @Environment(\.interfaceStyle) private var style

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            TypefluxSheet(title: L("clipboard.edit.title"), cancelTitle: L("clipboard.edit.cancel"),
                          confirmTitle: L("clipboard.action.paste"),
                          cancelShortcut: nil, confirmShortcut: nil,
                          cancel: model.cancelEdit, confirm: model.commitEdit) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: Binding(get: { model.editingText ?? "" }, set: { model.editingText = $0 }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(
                            cornerRadius: TypefluxRadius.textField.value(for: style), style: .continuous
                        ))
                        .focused($focused)
                    Text(L("clipboard.edit.hint"))
                        .font(.subheadline).foregroundStyle(TypefluxColor.secondaryLabel.color)
                }
            }
            .frame(width: 480, height: 320)
        }
        .onAppear { focused = true }
    }
}

/// Asks before a destructive panel command; Return confirms and Escape cancels.
struct ClipboardConfirmationBar: View {
    let message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        TypefluxGlassContainer(radius: .popover) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TypefluxColor.warning.color)
                Text(message).font(.callout).lineLimit(2)
                Spacer()
                TypefluxButton(L("clipboard.edit.cancel"), action: onCancel)
                TypefluxButton(L("clipboard.action.delete"), kind: .destructive, action: onConfirm)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .padding(.horizontal, 12).padding(.bottom, 40)
    }
}
