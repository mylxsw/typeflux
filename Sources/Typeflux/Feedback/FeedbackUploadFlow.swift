import Foundation

/// The sign-in an uploaded feedback image belongs to. The API ties an
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

/// Uploads feedback images and assembles the submission for one sign-in.
///
/// The upload ticket and the PUT use one credential, read once. The
/// submission reads the current credential again (its access token may have
/// been refreshed meanwhile); images uploaded under a different sign-in are
/// refused instead of being attached to another account's feedback.
enum FeedbackUploadFlow {
    /// Uploads `image` for `credential` (nil uploads anonymously) and returns
    /// the image URL to attach to the feedback.
    static func upload(
        _ image: PreparedFeedbackImage,
        credential: TypefluxCloudSessionCredential?,
        executor: CloudRequestExecutor = CloudRequestExecutor(),
        session: CloudHTTPSession = URLSession.shared
    ) async throws -> String {
        let token = credential?.accessToken
        let target = try await FeedbackAPIService.createImageUploadTarget(
            filename: image.filename,
            contentType: image.contentType,
            sizeBytes: Int64(image.data.count),
            token: token,
            executor: executor
        )
        try Task.checkCancellation()
        try await FeedbackAPIService.uploadImage(
            data: image.data,
            filename: image.filename,
            contentType: image.contentType,
            to: target,
            token: token,
            session: session
        )
        try Task.checkCancellation()
        return target.imageURL
    }

    /// The image URLs to submit as `owner`. Throws, and lists the stale
    /// images, when any finished upload belongs to another sign-in.
    static func submissionImageURLs(
        for images: [FeedbackImageAttachment],
        submittingAs owner: FeedbackUploadOwner
    ) throws -> [String] {
        let stale = images.filter { $0.state.uploadedURL != nil && $0.uploadOwner != owner }
        guard stale.isEmpty else {
            throw FeedbackUploadOwnerError(staleImageIDs: stale.map(\.id))
        }
        return images.compactMap(\.state.uploadedURL)
    }
}

/// Some uploaded images belong to a sign-in other than the submitting one.
struct FeedbackUploadOwnerError: LocalizedError, Equatable {
    let staleImageIDs: [UUID]

    var errorDescription: String? {
        L("feedback.error.accountChanged")
    }
}
