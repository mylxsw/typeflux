import AppKit
import SwiftUI

/// The standalone feedback window: a one-line intro, the rich text editor with its toolbar and
/// rules, an optional contact, and the footer with the other ways to reach us.
struct FeedbackWindowView: View {
    @ObservedObject var model: FeedbackWindowModel
    let onClose: () -> Void
    let onCaptureScreenshot: () -> Void
    @StateObject private var toolbar = FeedbackToolbarState()

    static let defaultSize = CGSize(width: 600, height: 660)
    static let minimumSize = CGSize(width: 520, height: 560)

    var body: some View {
        Group {
            switch model.phase {
            case .editing: editingBody
            case .submitted: successBody
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(StudioTheme.windowBackground)
        .foregroundStyle(StudioTheme.textPrimary)
        .tint(StudioTheme.accent)
        .background {
            // ⌘W closes the window like every other app window.
            Button("", action: onClose).keyboardShortcut("w", modifiers: .command).opacity(0)
        }
    }

    // MARK: - Editing

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: StudioTheme.Spacing.mediumLarge) {
            Text(L("feedback.direct.intro"))
                .font(.studioBody(13))
                .foregroundStyle(StudioTheme.textSecondary)

            if model.isDraftRestored {
                draftNotice
            }

            editor

            contactField

            if let message = model.errorMessage {
                Text(message)
                    .font(.studioBody(12))
                    .foregroundStyle(StudioTheme.danger)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTheme.danger.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 6)
    }

    private var draftNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            Text(L("feedback.draft.restored"))
            Button(L("feedback.draft.clear")) { model.reset() }
                .buttonStyle(.link)
        }
        .font(.studioBody(12))
        .foregroundStyle(StudioTheme.textSecondary)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            FeedbackToolbar(
                model: model,
                state: toolbar,
                onCaptureScreenshot: onCaptureScreenshot
            )
            Divider().overlay(StudioTheme.border.opacity(0.5))
            FeedbackEditorView(model: model, toolbar: toolbar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(StudioTheme.border.opacity(0.5))
            statusRow
        }
        .background(StudioTheme.controlSurface)
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.72), lineWidth: 1)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let notice = model.notice {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(StudioTheme.danger)
                Text(notice).foregroundStyle(StudioTheme.danger).lineLimit(2)
            } else {
                Text(model.statusLine)
                    .foregroundStyle(StudioTheme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(L("feedback.attachment.count", model.attachmentCountText))
                .foregroundStyle(StudioTheme.textTertiary)
                .monospacedDigit()
        }
        .font(.studioBody(11.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var contactField: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .foregroundStyle(StudioTheme.textTertiary)
            TextField(L("feedback.direct.contactPlaceholder"), text: $model.contact)
                .textFieldStyle(.plain)
                .font(.studioBody(13))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(StudioTheme.controlSurface)
        .clipShape(RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioTheme.CornerRadius.medium, style: .continuous)
                .stroke(StudioTheme.border.opacity(0.72), lineWidth: 1)
        }
        .accessibilityLabel(L("feedback.direct.contactLabel"))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            alternativeLinks
            Spacer()
            StudioButton(
                title: L("common.cancel"), systemImage: nil, variant: .secondary,
                isDisabled: model.isSubmitting, action: onClose
            )
            .keyboardShortcut(.cancelAction)
            StudioButton(
                title: L("feedback.direct.submit"), systemImage: nil, variant: .primary,
                isDisabled: !model.canSubmit, isLoading: model.isSubmitting,
                action: model.submit
            )
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var alternativeLinks: some View {
        HStack(spacing: 6) {
            Text(L("feedback.footer.other"))
                .foregroundStyle(StudioTheme.textTertiary)
            ForEach([FeedbackDestination.email, .github]) { destination in
                Button(destination.shortTitle) {
                    if let url = destination.url {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
        .font(.studioBody(12))
    }

    // MARK: - Success

    private var successBody: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(StudioTheme.success)
            Text(L("feedback.success.title"))
                .font(.studioDisplay(20, weight: .semibold))
            if let contact = model.submittedContact {
                Text(L("feedback.success.replyTo", contact))
                    .font(.studioBody(13))
                    .foregroundStyle(StudioTheme.textSecondary)
            }
            HStack(spacing: 12) {
                StudioButton(
                    title: L("feedback.success.another"), systemImage: nil, variant: .secondary,
                    action: model.reset
                )
                StudioButton(
                    title: L("common.done"), systemImage: nil, variant: .primary, action: onClose
                )
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Formatting buttons and the attachment actions above the editor.
private struct FeedbackToolbar: View {
    @ObservedObject var model: FeedbackWindowModel
    @ObservedObject var state: FeedbackToolbarState
    let onCaptureScreenshot: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            toggle("bold", L("feedback.editor.bold"), active: state.bold) { $0.toggleInline(.bold) }
            toggle("italic", L("feedback.editor.italic"), active: state.italic) { $0.toggleInline(.italic) }
            toggle("strikethrough", L("feedback.editor.strikethrough"), active: state.strikethrough) {
                $0.toggleInline(.strikethrough)
            }
            separator
            toggle("textformat.size", L("feedback.editor.heading"), active: state.block == .heading) {
                $0.toggleBlock(.heading)
            }
            toggle("list.bullet", L("feedback.editor.bulletList"), active: state.block == .bulletList) {
                $0.toggleBlock(.bulletList)
            }
            toggle("list.number", L("feedback.editor.numberedList"), active: state.block == .numberedList) {
                $0.toggleBlock(.numberedList)
            }
            toggle("text.quote", L("feedback.editor.quote"), active: state.block == .quote) {
                $0.toggleBlock(.quote)
            }
            toggle("chevron.left.forwardslash.chevron.right", L("feedback.editor.code"), active: state.block == .code) {
                $0.toggleCode()
            }
            toggle("link", L("feedback.editor.link"), active: false) {
                FeedbackEditorView.promptForLink(in: $0)
            }
            Spacer(minLength: 8)
            Button(action: chooseFiles) {
                Label(L("feedback.attachment.add"), systemImage: "paperclip")
            }
            .disabled(!model.canAddAttachments)
            Button(action: onCaptureScreenshot) {
                Label(L("feedback.attachment.screenshot"), systemImage: "camera.viewfinder")
            }
            .disabled(!model.canAddAttachments)
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.studioBody(12))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var separator: some View {
        Divider().frame(height: 14).padding(.horizontal, 4)
    }

    private func toggle(
        _ symbol: String,
        _ help: String,
        active: Bool,
        action: @escaping (FeedbackTextView) -> Void
    ) -> some View {
        Button {
            guard let textView = model.editor.textView else { return }
            textView.window?.makeFirstResponder(textView)
            action(textView)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(active ? StudioTheme.accentSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .help(help)
        .accessibilityLabel(help)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        model.addFiles(panel.urls)
    }
}
