import AppKit
import SwiftUI

enum FeedbackImageUploadState: Equatable {
    case preparing
    case uploading
    case uploaded(String)
    case failed(String)

    var isReady: Bool {
        if case .uploaded = self { return true }
        return false
    }

    var isInProgress: Bool {
        switch self {
        case .preparing, .uploading:
            true
        case .uploaded, .failed:
            false
        }
    }

    var uploadedURL: String? {
        if case let .uploaded(url) = self { return url }
        return nil
    }
}

struct FeedbackImageAttachment: Identifiable {
    let id: UUID
    var filename: String
    var thumbnail: NSImage?
    var state: FeedbackImageUploadState
    /// The sign-in that uploaded the image; set when the upload finishes.
    var uploadOwner: FeedbackUploadOwner?

    init(
        id: UUID = UUID(),
        filename: String,
        thumbnail: NSImage? = nil,
        state: FeedbackImageUploadState,
        uploadOwner: FeedbackUploadOwner? = nil
    ) {
        self.id = id
        self.filename = filename
        self.thumbnail = thumbnail
        self.state = state
        self.uploadOwner = uploadOwner
    }
}

struct DirectFeedbackSheet: View {
    @Binding var content: String
    @Binding var contact: String
    @Binding var images: [FeedbackImageAttachment]
    let isSubmitting: Bool
    let errorMessage: String?
    let onAddImages: () -> Void
    let onRemoveImage: (FeedbackImageAttachment.ID) -> Void
    let onCancel: () -> Void
    let onSubmit: () -> Void

    private let contentPlaceholderHorizontalPadding: CGFloat = 13
    private let contentPlaceholderVerticalPadding: CGFloat = 15

    private var canSubmit: Bool {
        FeedbackSubmissionReadiness.canSubmit(content: content, images: images)
    }

    var body: some View {
        TypefluxGlassContainer(radius: .sheet, placement: .inWindow) {
            VStack(alignment: .leading, spacing: TypefluxSpacing.large.value(for: .classic)) {
                Text(L("feedback.direct.title"))
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(TypefluxColor.label.color)

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("feedback.direct.contentLabel"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)

                    ZStack(alignment: .topLeading) {
                        FeedbackContentTextView(text: $content)
                            .font(.system(.body))
                            .frame(minHeight: 160)
                            .accessibilityLabel(L("feedback.direct.contentLabel"))
                            .accessibilityIdentifier("feedback.content")
                            .background(TypefluxColor.controlBackground.color)
                            .clipShape(RoundedRectangle(
                                cornerRadius: TypefluxRadius.form.value(for: .classic),
                                style: .continuous
                            ))
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: TypefluxRadius.form.value(for: .classic),
                                    style: .continuous
                                )
                                .stroke(TypefluxColor.separator.color.opacity(0.72), lineWidth: 1)
                            }

                        if content.isEmpty {
                            Text(L("feedback.direct.contentPlaceholder"))
                                .font(.system(.body))
                                .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                                .padding(.horizontal, contentPlaceholderHorizontalPadding)
                                .padding(.vertical, contentPlaceholderVerticalPadding)
                                .fixedSize(horizontal: false, vertical: true)
                                .allowsHitTesting(false)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("feedback.direct.imagesLabel"))
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(TypefluxColor.secondaryLabel.color)

                        Spacer()

                        TypefluxButton(action: onAddImages) {
                            Label(L("feedback.direct.addImage"), systemImage: "plus")
                        }
                        .disabled(isSubmitting || images.count >= 4)
                    }

                    if !images.isEmpty {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(68), spacing: 10),
                                count: 4
                            ),
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(images) { image in
                                FeedbackImageThumbnail(
                                    image: image,
                                    onRemove: { onRemoveImage(image.id) }
                                )
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L("feedback.direct.contactLabel"))
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(TypefluxColor.secondaryLabel.color)

                    TypefluxTextField(L("feedback.direct.contactLabel"), text: $contact,
                                      prompt: L("feedback.direct.contactPlaceholder"))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(.callout))
                        .foregroundStyle(TypefluxColor.danger.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()

                    TypefluxButton(L("common.cancel"), action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("feedback.cancel")
                        .disabled(isSubmitting)

                    TypefluxButton(kind: .primary) {
                        onSubmit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(L("feedback.direct.submit"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting || !canSubmit)
                    .accessibilityIdentifier("feedback.submit")
                    .accessibilityLabel(L("feedback.direct.submit"))
                }
            }
            .padding(24)
            .frame(width: 480)
        }
    }
}

private struct FeedbackContentTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.string = text
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor

        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private struct FeedbackImageThumbnail: View {
    let image: FeedbackImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                    .fill(TypefluxColor.controlBackground.color)

                if let thumbnail = image.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(
                            cornerRadius: TypefluxRadius.form.value(for: .classic),
                            style: .continuous
                        ))
                } else {
                    Image(systemName: "photo")
                        .font(.system(.title2, weight: .medium))
                        .foregroundStyle(TypefluxColor.tertiaryLabel.color)
                }

                statusOverlay
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: TypefluxRadius.form.value(for: .classic), style: .continuous)
                    .stroke(TypefluxColor.separator.color.opacity(0.72), lineWidth: 1)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(.title3, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(TypefluxColor.label.color, TypefluxColor.controlBackground.color.opacity(0.92))
            }
            .buttonStyle(.plain)
            .padding(4)
            .accessibilityLabel(L("feedback.direct.removeImage"))
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch image.state {
        case .preparing, .uploading:
            Rectangle()
                .fill(.black.opacity(0.32))
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        case .uploaded:
            EmptyView()
        case .failed:
            Rectangle()
                .fill(TypefluxColor.danger.color.opacity(0.76))
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)
                }
        }
    }
}
