import Foundation

/// The work behind the feedback window — compressing media, uploading and submitting — behind
/// one seam so the window model can be tested without media codecs or a network.
protocol FeedbackServicing: Sendable {
    func credential() async -> TypefluxCloudSessionCredential?
    func prepareImage(data: Data, filename: String) async throws -> PreparedFeedbackFile
    func prepareVideo(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedFeedbackFile
    func upload(_ file: PreparedFeedbackFile, credential: TypefluxCloudSessionCredential?) async throws -> String
    func submit(
        content: String,
        contact: String?,
        attachments: [FeedbackAttachmentPayload],
        credential: TypefluxCloudSessionCredential?
    ) async throws
}

struct LiveFeedbackServices: FeedbackServicing {
    func credential() async -> TypefluxCloudSessionCredential? {
        await AuthState.shared.validSessionCredential()
    }

    func prepareImage(data: Data, filename: String) async throws -> PreparedFeedbackFile {
        try await Task.detached(priority: .utility) {
            try FeedbackImageProcessor.prepare(imageData: data, filename: filename)
        }.value
    }

    func prepareVideo(
        url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedFeedbackFile {
        try await FeedbackVideoCompressor.compress(url: url, progress: progress)
    }

    func upload(_ file: PreparedFeedbackFile, credential: TypefluxCloudSessionCredential?) async throws -> String {
        try await FeedbackUploadFlow.upload(file, credential: credential)
    }

    func submit(
        content: String,
        contact: String?,
        attachments: [FeedbackAttachmentPayload],
        credential: TypefluxCloudSessionCredential?
    ) async throws {
        _ = try await FeedbackAPIService.submit(
            content: content,
            contact: contact,
            imageURLs: FeedbackUploadFlow.imageURLs(of: attachments),
            attachments: attachments,
            token: credential?.accessToken
        )
    }
}

extension FeedbackAttachmentPayload {
    /// How the attachment appears in the Markdown body: images inline, other files as links.
    var markdown: String {
        let name = filename.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return kind == FeedbackAttachmentKind.image.apiValue ? "![\(name)](\(url))" : "[\(name)](\(url))"
    }
}
