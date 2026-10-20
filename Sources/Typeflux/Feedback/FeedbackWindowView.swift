import AppKit
import SwiftUI

/// The standalone feedback window (`docs/design/feedback-window.md` §9): a pane header, the rich
/// text editor with its toolbar and rules, the contact field and a sheet-style footer. Every
/// control comes from the component library (`UI/Components`).
struct FeedbackWindowView: View {
    @ObservedObject var model: FeedbackWindowModel
    let onClose: () -> Void
    let onCaptureScreenshot: () -> Void
    @StateObject private var toolbar = FeedbackToolbarState()

    /// Both sizes include the 52pt title bar row, which sits inside the content view.
    static let defaultSize = CGSize(width: 600, height: 720)
    static let minimumSize = CGSize(width: 520, height: 640)
    /// The empty unified toolbar gives the title bar row the 52pt height of the other windows.
    static let titleBarHeight: CGFloat = 52
    static let contactLabelWidth: CGFloat = 72

    var body: some View {
        Group {
            switch model.phase {
            case .editing: editingBody
            case .submitted: successBody
            }
        }
        .padding(.top, Self.titleBarHeight)
        .foregroundStyle(TFColors.textPrimary)
        // One surface for the whole window, as in the notebook and usage guide windows.
        .background(AskWindowBackdrop())
        .ignoresSafeArea(.container, edges: .top)
        // The whole window, title bar row included; the controller sets the same window minimum.
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .tint(TFColors.accent)
        .tfControlSize(.regular)
        .background {
            // ⌘W closes the window like every other app window.
            Button("", action: onClose).keyboardShortcut("w", modifiers: .command).opacity(0)
        }
    }

    // MARK: - Editing

    private var editingBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                TFPaneHeader(
                    systemImage: "exclamationmark.bubble",
                    title: L("feedback.direct.title"),
                    subtitle: L("feedback.direct.intro")
                )

                if model.isDraftRestored {
                    draftNotice
                }

                editor

                if let notice = model.notice {
                    TFFieldMessage(text: notice, tone: .warning)
                        .padding(.top, -8)
                }

                contactField

                if let message = model.errorMessage {
                    TFNotice(text: message, tone: .danger)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            TFDivider(inset: 0)
            footer
        }
    }

    private var draftNotice: some View {
        TFNotice(text: L("feedback.draft.restored"), tone: .info)
            .overlay(alignment: .trailing) {
                TFButton(title: L("feedback.draft.clear"), kind: .link, size: .small, action: model.reset)
                    .padding(.trailing, 8)
            }
    }

    private var editor: some View {
        let shape = RoundedRectangle(cornerRadius: TFMetrics.textAreaCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            FeedbackToolbar(model: model, state: toolbar, onCaptureScreenshot: onCaptureScreenshot)
            TFDivider(inset: 0)
            FeedbackEditorView(model: model, toolbar: toolbar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            TFDivider(inset: 0)
            statusRow
        }
        .background(shape.fill(TFColors.control))
        .clipShape(shape)
        .overlay(shape.strokeBorder(TFColors.border, lineWidth: TFMetrics.borderWidth))
    }

    /// The footnote row: what blocks the submission, else the attachment rules, and the count.
    private var statusRow: some View {
        HStack(spacing: 8) {
            Text(model.statusLine)
                .foregroundStyle(model.isStatusLineWarning ? TFColors.danger : TFColors.textTertiary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(L("feedback.attachment.count", model.attachmentCountText))
                .foregroundStyle(TFColors.textTertiary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(minHeight: 30)
    }

    /// The `TFLabeledField` layout without its card padding: a 13pt label column and a 30pt field.
    private var contactField: some View {
        HStack(spacing: 14) {
            Text(L("feedback.direct.contactField"))
                .font(.system(size: 13))
                .foregroundStyle(TFColors.textSecondary)
                .frame(width: Self.contactLabelWidth, alignment: .leading)
            TextField(L("feedback.direct.contactFieldPlaceholder"), text: $model.contact)
                .textFieldStyle(TFTextFieldStyle())
                .accessibilityLabel(L("feedback.direct.contactField"))
        }
    }

    /// Sheet footer: one menu link on the left, `[Cancel] [Submit]` on the right.
    private var footer: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            TFMenuButton(
                title: L("feedback.footer.otherMenu"),
                kind: .link,
                actions: [FeedbackDestination.email, .github].map { destination in
                    .action(destination.title) {
                        if let url = destination.url {
                            NSWorkspace.shared.open(url)
                        }
                    }
                },
                identifier: "feedback.footer.otherMenu"
            )
            Spacer()
            TFButton(title: L("common.cancel"), action: onClose)
                .disabled(model.isSubmitting)
                .keyboardShortcut(.cancelAction)
            TFButton(
                title: L("feedback.direct.submit"),
                kind: .primary,
                isLoading: model.isSubmitting,
                action: model.submit
            )
            .disabled(!model.canSubmit)
            .keyboardShortcut(.return, modifiers: .command)
            .help(L("feedback.direct.submitHelp"))
        }
        .padding(.horizontal, 24)
        .frame(height: 62)
    }

    // MARK: - Success

    private var successBody: some View {
        TFEmptyState(
            systemImage: "checkmark",
            title: L("feedback.success.title"),
            message: model.submittedContact.map { L("feedback.success.replyTo", $0) }
        ) {
            TFButton(title: L("common.done"), kind: .primary, size: .large, action: onClose)
                .keyboardShortcut(.defaultAction)
            TFButton(title: L("feedback.success.another"), kind: .link, action: model.reset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Formatting buttons and the attachment actions above the editor: small plain buttons, icon-only
/// ones are 24pt circles, groups separated by a hairline.
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
            toggle("link", L("feedback.editor.link"), active: false) { _ in
                state.requestLinkEntry(in: model.editor.textView)
            }
            .popover(isPresented: $state.isLinkEntryPresented, arrowEdge: .bottom) {
                FeedbackLinkEntry(textView: model.editor.textView) { state.isLinkEntryPresented = false }
            }
            Spacer(minLength: 8)
            TFButton(title: L("feedback.attachment.add"), systemImage: "paperclip", kind: .plain, action: chooseFiles)
                .disabled(!model.canAddAttachments)
                .help(L("feedback.attachment.addHelp"))
            TFButton(
                title: L("feedback.attachment.screenshot"),
                systemImage: "camera.viewfinder",
                kind: .plain,
                action: onCaptureScreenshot
            )
            .disabled(!model.canAddAttachments)
            .help(L("feedback.attachment.screenshotHelp"))
        }
        .tfControlSize(.small)
        .padding(.horizontal, 6)
        .frame(height: 36)
    }

    private var separator: some View {
        Rectangle()
            .fill(TFColors.border)
            .frame(width: TFMetrics.borderWidth, height: 14)
            .padding(.horizontal, 6)
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
                .font(.system(size: TFControlSize.small.iconSize, weight: .semibold))
                .foregroundStyle(active ? TFColors.textPrimary : TFColors.textSecondary)
        }
        .buttonStyle(TFButtonStyle(kind: .plain, size: .small, iconOnly: true))
        // An active format keeps the pressed overlay, so it reads as switched on.
        .background(Capsule(style: .circular).fill(active ? TFColors.pressedOverlay : .clear))
        .disabled(model.isSubmitting)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
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

/// The link popover: a 30pt field and a primary button. An empty field removes the link; only
/// http and https targets are accepted.
private struct FeedbackLinkEntry: View {
    weak var textView: FeedbackTextView?
    let onDone: () -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: TFMetrics.toolbarSpacing) {
            TextField("https://", text: $text)
                .textFieldStyle(TFTextFieldStyle())
                .frame(width: 260)
                .onSubmit(apply)
                .accessibilityLabel(L("feedback.editor.link.title"))
            TFButton(title: L("feedback.editor.link.apply"), kind: .primary, action: apply)
        }
        .padding(TFMetrics.menuPadding + 5)
        .help(L("feedback.editor.link.message"))
        .onAppear { text = textView?.currentLinkURL?.absoluteString ?? "" }
    }

    private func apply() {
        if let textView {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            textView.window?.makeFirstResponder(textView)
            textView.applyLink(trimmed.isEmpty ? nil : FeedbackRichText.normalizedLinkURL(trimmed))
        }
        onDone()
    }
}
