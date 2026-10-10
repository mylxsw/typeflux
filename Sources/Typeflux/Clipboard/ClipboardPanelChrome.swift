import SwiftUI

/// Pause, preview pane, settings and more, right of the clipboard panel's type tabs.
struct ClipboardPanelToolbar: View {
    @ObservedObject var model: ClipboardPanelModel

    var body: some View {
        HStack(spacing: 2) {
            button(
                symbol: model.isRecordingPaused ? "pause.circle.fill" : "pause.circle",
                help: L(model.isRecordingPaused ? "clipboard.toolbar.resume" : "clipboard.toolbar.pause"),
                tint: model.isRecordingPaused ? Color.orange : nil
            ) { model.send(.togglePause) }
            button(
                symbol: "sidebar.right", help: L("clipboard.toolbar.preview"),
                tint: model.showsPreview ? Color.accentColor : nil
            ) { model.togglePreview() }
            button(symbol: "gearshape", help: L("clipboard.toolbar.settings"), tint: nil) {
                model.send(.openSettings)
            }
            moreMenu
        }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StudioTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("clipboard.toolbar.more"))
    }

    private func button(symbol: String, help: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? StudioTheme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The app the list is filtered to, in the search bar, with a button to show every app again.
struct ClipboardAppFilterChip: View {
    let app: ClipboardAppFilter
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(app.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .help(L("clipboard.filter.clear"))
            .accessibilityLabel(L("clipboard.filter.clear"))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .fixedSize()
    }
}

/// The footer's pause notice — the only place the pause shows besides the toolbar. Clicking resumes.
struct ClipboardPausedChip: View {
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: 5) {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text(L("clipboard.footer.paused"))
            }
            .font(.system(size: 11.5, weight: .medium))
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            VStack(alignment: .leading, spacing: 10) {
                Text(L("clipboard.edit.title"))
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: Binding(get: { model.editingText ?? "" }, set: { model.editingText = $0 }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .focused($focused)
                HStack(spacing: 8) {
                    Text(L("clipboard.edit.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.textSecondary)
                    Spacer()
                    Button(L("clipboard.edit.cancel"), action: model.cancelEdit)
                    Button(L("clipboard.action.paste"), action: model.commitEdit)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 520, height: 320)
            .background(AskTheme.launcherSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
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
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button(L("clipboard.edit.cancel"), action: onCancel)
            Button(L("clipboard.action.delete"), role: .destructive, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 48)
    }
}
