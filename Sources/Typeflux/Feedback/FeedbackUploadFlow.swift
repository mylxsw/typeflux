import Foundation

/// The sign-in an uploaded feedback attachment belongs to. The API ties an
/// account upload to that account, so an image may only be submitted by the
/// same sign-in that uploaded it.
enum FeedbackUploadOwner: Equatable, Sendable {
    case anonymous
    case session(Int)

    init(_ credential: TypefluxCloudSessionCredential?) {
        if let credential {
            self = .session(credential.session)
        } else {
            self = .anonymous
        }
    }
}

/// Uploads feedback attachments and assembles the submission for one sign-in.
///
/// The upload ticket and the PUT use one credential, read once. The
/// submission reads the current credential again (its access token may have
/// been refreshed meanwhile); images uploaded under a different sign-in are
/// refused instead of being attached to another account's feedback.
enum FeedbackUploadFlow {
    /// Uploads `file` for `credential` (nil uploads anonymously) and returns
    /// the URL to attach to the feedback.
    static func upload(
        _ file: PreparedFeedbackFile,
        credential: TypefluxCloudSessionCredential?,
        executor: CloudRequestExecutor = CloudRequestExecutor(),
        session: CloudHTTPSession = URLSession.shared
    ) async throws -> String {
        let token = credential?.accessToken
        let target = try await FeedbackAPIService.createUploadTarget(
            filename: file.filename,
            contentType: file.contentType,
            sizeBytes: Int64(file.data.count),
            token: token,
            executor: executor
        )
        try Task.checkCancellation()
        try await FeedbackAPIService.uploadFile(
            data: file.data,
            filename: file.filename,
            contentType: file.contentType,
            to: target,
            token: token,
            session: session
        )
        try Task.checkCancellation()
        return target.imageURL
    }

    /// The uploaded attachments to submit as `owner`. Throws, and lists the stale
    /// attachments, when any finished upload belongs to another sign-in.
    static func submissionAttachments(
        for attachments: [FeedbackAttachment],
        submittingAs owner: FeedbackUploadOwner
    ) throws -> [FeedbackAttachmentPayload] {
        let stale = attachments.filter { $0.state.uploadedURL != nil && $0.uploadOwner != owner }
        guard stale.isEmpty else {
            throw FeedbackUploadOwnerError(staleAttachmentIDs: stale.map(\.id))
        }
        return attachments.compactMap { attachment in
            attachment.state.uploadedURL.map {
                FeedbackAttachmentPayload(
                    url: $0,
                    filename: attachment.filename,
                    contentType: attachment.contentType,
                    sizeBytes: attachment.sizeBytes,
                    kind: attachment.kind.apiValue
                )
            }
        }
    }

    /// The image URLs of `attachments`, sent in the legacy `image_urls` field as well.
    static func imageURLs(of attachments: [FeedbackAttachmentPayload]) -> [String] {
        attachments.filter { $0.kind == FeedbackAttachmentKind.image.apiValue }.map(\.url)
    }
}

/// Some uploaded attachments belong to a sign-in other than the submitting one.
struct FeedbackUploadOwnerError: LocalizedError, Equatable {
    let staleAttachmentIDs: [UUID]

    var errorDescription: String? {
        L("feedback.error.accountChanged")
    }
}
