import SwiftUI

/// The more menu in the clipboard panel's hint bar.
struct ClipboardPanelToolbar: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        moreMenu
    }

    private var moreMenu: some View {
        Menu {
            Button(L(model.isRecordingPaused ? "clipboard.toolbar.resume" : "clipboard.toolbar.pause")) {
                model.send(.togglePause)
            }
            Button(L(model.showsPreview ? "clipboard.menu.hidePreview" : "clipboard.menu.showPreview")) {
                model.togglePreview()
            }
            Divider()
            Button(L("clipboard.toolbar.settings")) { model.send(.openSettings) }
            Divider()
            Button(L("clipboard.menu.clearUnpinned"), role: .destructive) { model.requestClearUnpinned() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(model.isRecordingPaused ? Color.orange : TypefluxColor.secondaryLabel.color)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("clipboard.toolbar.more"))
        .accessibilityLabel(L("clipboard.toolbar.more"))
    }
}

/// The app filter in the hint bar, with a button to show every app again.
struct ClipboardAppFilterChip: View {
    let app: ClipboardAppFilter
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(app.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
            }
            .buttonStyle(.plain)
            .help(L("clipboard.filter.clear"))
            .accessibilityLabel(L("clipboard.filter.clear"))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .frame(maxWidth: 220, alignment: .leading)
    }
}

/// The footer's pause notice. Clicking resumes recording.
struct ClipboardPausedChip: View {
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(L("clipboard.footer.paused"))
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
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
                            cornerRadius: TypefluxRadius.textField.value(for: style), style: .continuous))
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
        .padding(.horizontal, 12).padding(.bottom, 76)
    }
}
