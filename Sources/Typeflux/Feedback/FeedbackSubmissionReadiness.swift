import Foundation

/// A submission must contain text and only successfully uploaded attachments.
enum FeedbackSubmissionReadiness {
    static func canSubmit(content: String, images: [FeedbackImageAttachment]) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.allSatisfy { $0.state.isReady }
    }
}
