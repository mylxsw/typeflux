import Testing
@testable import Typeflux

struct FeedbackSubmissionReadinessTests {
    @Test func emptyAndWhitespaceAreRejected() {
        for text in ["", " ", "\n\t "] {
            #expect(!FeedbackSubmissionReadiness.canSubmit(content: text, images: []))
        }
        #expect(FeedbackSubmissionReadiness.canSubmit(content: "  Useful feedback \n", images: []))
    }

    @Test func everyAttachmentMustBeSuccessfullyUploaded() {
        let ready = FeedbackImageAttachment(filename: "ready.png", state: .uploaded("https://example.test/image.png"))
        #expect(FeedbackSubmissionReadiness.canSubmit(content: "Feedback", images: [ready, ready]))
        for state in [FeedbackImageUploadState.preparing, .uploading, .failed("Failed")] {
            let pending = FeedbackImageAttachment(filename: "pending.png", state: state)
            #expect(!FeedbackSubmissionReadiness.canSubmit(content: "Feedback", images: [pending]))
            #expect(!FeedbackSubmissionReadiness.canSubmit(content: "Feedback", images: [ready, pending]))
        }
        #expect(!FeedbackSubmissionReadiness.canSubmit(content: "", images: [ready]))
    }
}
