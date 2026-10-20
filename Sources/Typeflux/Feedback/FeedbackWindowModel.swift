import AppKit
import Combine

/// Connects the model to the editor's text view, which the SwiftUI view creates.
@MainActor
final class FeedbackEditorBridge {
    weak var textView: FeedbackTextView?
    /// Looks up the attachment a block draws; set by the model.
    var attachmentProvider: (UUID) -> FeedbackAttachment? = { _ in nil }

    var attributedText: NSAttributedString {
        textView?.attributedString() ?? NSAttributedString()
    }

    func insert(_ attachment: FeedbackTextAttachment) {
        attachment.attachmentCell = FeedbackAttachmentCell(
            attachmentID: attachment.attachmentID, provider: attachmentProvider
        )
        textView?.insertAttachmentBlock(attachment)
    }

    func removeAttachmentBlock(id: UUID) {
        textView?.removeAttachmentBlock(id: id)
    }

    func refreshAttachment(id: UUID) {
        textView?.refreshAttachment(id: id)
    }

    var attachmentIDs: [UUID] {
        textView?.attachmentIDs ?? []
    }

    func clear() {
        guard let textView else { return }
        textView.textStorage?.setAttributedString(NSAttributedString())
        textView.typingAttributes = FeedbackRichText.baseAttributes
        textView.needsDisplay = true
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

enum FeedbackWindowPhase: Equatable {
    case editing, submitted
}

/// State of the feedback window. It outlives the window being closed, so a draft survives
/// closing and reopening until it is submitted or cleared.
@MainActor
final class FeedbackWindowModel: ObservableObject {
    @Published var contact = ""
    @Published var attachments: [FeedbackAttachment] = []
    @Published private(set) var hasText = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var phase: FeedbackWindowPhase = .editing
    @Published var errorMessage: String?
    /// Why the last file was not added; cleared when the next file is added.
    @Published var notice: String?
    @Published private(set) var isDraftRestored = false
    @Published private(set) var submittedContact: String?

    let editor = FeedbackEditorBridge()
    let services: FeedbackServicing
    private let defaultContact: () -> String
    var tasks: [UUID: Task<Void, Never>] = [:]
    var previewURLs: [UUID: URL] = [:]
    private var submitTask: Task<Void, Never>?

    init(services: FeedbackServicing = LiveFeedbackServices(), defaultContact: @escaping () -> String = { "" }) {
        self.services = services
        self.defaultContact = defaultContact
        contact = defaultContact()
        editor.attachmentProvider = { [weak self] id in
            MainActor.assumeIsolated { self?.attachment(id: id) }
        }
    }

    // MARK: - Derived state

    var hasDraft: Bool {
        hasText || !attachments.isEmpty
    }

    var canAddAttachments: Bool {
        !isSubmitting && attachments.count < FeedbackAttachmentPolicy.maxAttachmentCount
    }

    var canSubmit: Bool {
        hasText && !isSubmitting && !attachments.contains { $0.state.isBlockingSubmit }
    }

    /// The line under the editor: the first thing blocking the submission, else the rules.
    var statusLine: String {
        if let failed = attachments.first(where: {
            if case .failed = $0.state {
                true
            } else {
                false
            }
        }) {
            return L("feedback.status.failed") + " " + failed.filename
        }
        if attachments.contains(where: {
            if case .rejected = $0.state {
                true
            } else {
                false
            }
        }) {
            return L("feedback.status.rejected")
        }
        if attachments.contains(where: \.state.isInProgress) {
            return L("feedback.status.busy")
        }
        return L("feedback.status.rules")
    }

    /// The status line names a failed or oversized attachment rather than the rules.
    var isStatusLineWarning: Bool {
        attachments.contains(where: \.state.isError)
    }

    var attachmentCountText: String {
        "\(attachments.count)/\(FeedbackAttachmentPolicy.maxAttachmentCount)"
    }

    func attachment(id: UUID) -> FeedbackAttachment? {
        attachments.first { $0.id == id }
    }

    // MARK: - Lifecycle

    /// Called each time the window is shown.
    func windowWillShow() {
        if phase == .submitted {
            reset()
        }
        isDraftRestored = hasDraft
        if contact.isEmpty, !hasDraft {
            contact = defaultContact()
        }
    }

    /// Clears the draft: text, attachments (their uploads are cancelled) and errors.
    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        submitTask?.cancel()
        submitTask = nil
        previewURLs = [:]
        attachments = []
        editor.clear()
        hasText = false
        contact = defaultContact()
        errorMessage = nil
        notice = nil
        isSubmitting = false
        isDraftRestored = false
        submittedContact = nil
        phase = .editing
    }

    // MARK: - Editing

    /// Called by the editor when its content changed.
    func editorDidChange() {
        let text = editor.attributedText.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !text.isEmpty
        if self.hasText != hasText {
            self.hasText = hasText
        }

        // An attachment block deleted in the editor (or restored by undo) must stay in step.
        let inEditor = Set(editor.attachmentIDs)
        for attachment in attachments where !inEditor.contains(attachment.id) {
            discard(id: attachment.id)
        }
        let known = Set(attachments.map(\.id))
        for id in inEditor where !known.contains(id) {
            editor.removeAttachmentBlock(id: id)
        }
        if errorMessage != nil {
            errorMessage = nil
        }
    }

    // MARK: - Submit

    func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        let contactText = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        submitTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = await services.credential()
                let payloads: [FeedbackAttachmentPayload]
                do {
                    payloads = try FeedbackUploadFlow.submissionAttachments(
                        for: attachments, submittingAs: FeedbackUploadOwner(credential)
                    )
                } catch let error as FeedbackUploadOwnerError {
                    // Never attach another sign-in's uploads; the user removes and re-adds them.
                    for id in error.staleAttachmentIDs {
                        update(id: id) { $0.state = .failed(error.localizedDescription) }
                    }
                    throw error
                }
                let byURL = Dictionary(payloads.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
                let content = FeedbackRichText.markdown(from: editor.attributedText) { [attachments] id in
                    attachments.first { $0.id == id }?.state.uploadedURL.flatMap { byURL[$0]?.markdown }
                }
                try await services.submit(
                    content: content,
                    contact: contactText.isEmpty ? nil : contactText,
                    attachments: payloads,
                    credential: credential
                )
                submittedContact = contactText.isEmpty ? nil : contactText
                let submittedContact = submittedContact
                reset()
                self.submittedContact = submittedContact
                phase = .submitted
            } catch is CancellationError {
                isSubmitting = false
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
