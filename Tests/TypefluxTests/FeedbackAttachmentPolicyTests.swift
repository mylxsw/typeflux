import Foundation
import Testing
@testable import Typeflux

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackAttachmentPolicyTests {
    private let mb: Int64 = 1024 * 1024

    @Test(arguments: [
        ("a.PNG", FeedbackAttachmentKind.image), ("a.jpeg", .image), ("a.heic", .image), ("a.gif", .image),
        ("a.mov", .video), ("a.mp4", .video), ("a.m4v", .video),
        ("a.txt", .file), ("a.log", .file), ("a.md", .file), ("a.docx", .file)
    ])
    func `kind follows the extension`(filename: String, kind: FeedbackAttachmentKind) {
        #expect(FeedbackAttachmentPolicy.kind(forFilename: filename) == kind)
        #expect(FeedbackAttachmentPolicy.contentType(forFilename: filename) != nil)
    }

    @Test(arguments: ["a.zip", "a.exe", "a.doc", "noext", "a.pdf"])
    func `unsupported types are refused`(filename: String) {
        #expect(FeedbackAttachmentPolicy.kind(forFilename: filename) == nil)
        #expect(FeedbackAttachmentPolicy.validate(filename: filename, sizeBytes: 1, currentCount: 0)
            == .unsupportedType(filename: filename))
        #expect(FeedbackAttachmentPolicy.validateUploadSize(filename: filename, sizeBytes: 1)
            == .unsupportedType(filename: filename))
    }

    @Test func `upload limits per type`() {
        #expect(FeedbackAttachmentPolicy.uploadLimit(forFilename: "a.png") == 3 * mb)
        #expect(FeedbackAttachmentPolicy.uploadLimit(forFilename: "a.mp4") == 50 * mb)
        #expect(FeedbackAttachmentPolicy.uploadLimit(forFilename: "a.log") == 5 * mb)
        #expect(FeedbackAttachmentPolicy.uploadLimit(forFilename: "a.docx") == 10 * mb)
        #expect(FeedbackAttachmentPolicy.uploadLimit(forFilename: "a.bin") == nil)
    }

    @Test func `images and videos are checked after compression, other files before`() {
        // A 20 MB screenshot or 500 MB recording is accepted: it is compressed first.
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.png", sizeBytes: 20 * mb, currentCount: 0) == nil)
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.mov", sizeBytes: 500 * mb, currentCount: 0) == nil)
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.log", sizeBytes: 5 * mb, currentCount: 0) == nil)
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.log", sizeBytes: 5 * mb + 1, currentCount: 0)
            == .tooLarge(filename: "a.log", limitBytes: 5 * mb))
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.docx", sizeBytes: 10 * mb + 1, currentCount: 0)
            == .tooLarge(filename: "a.docx", limitBytes: 10 * mb))
        // GIFs are not compressed, so their size is checked up front.
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.gif", sizeBytes: 4 * mb, currentCount: 0)
            == .tooLarge(filename: "a.gif", limitBytes: 3 * mb))
        #expect(!FeedbackAttachmentPolicy.isCompressed(filename: "a.gif"))
        #expect(FeedbackAttachmentPolicy.isCompressed(filename: "a.mov"))
    }

    @Test func `upload size is enforced after compression`() {
        #expect(FeedbackAttachmentPolicy.validateUploadSize(filename: "a.jpg", sizeBytes: 3 * mb) == nil)
        #expect(FeedbackAttachmentPolicy.validateUploadSize(filename: "a.jpg", sizeBytes: 3 * mb + 1)
            == .tooLarge(filename: "a.jpg", limitBytes: 3 * mb))
        #expect(FeedbackAttachmentPolicy.validateUploadSize(filename: "a.mp4", sizeBytes: 51 * mb)
            == .tooLarge(filename: "a.mp4", limitBytes: 50 * mb))
    }

    @Test func `the sixth attachment is accepted and the seventh is not`() {
        #expect(FeedbackAttachmentPolicy.validate(filename: "a.png", sizeBytes: 1, currentCount: 5) == nil)
        #expect(FeedbackAttachmentPolicy
            .validate(filename: "a.png", sizeBytes: 1, currentCount: 6) == .tooMany(limit: 6))
    }

    @Test func `limits read as round numbers`() {
        #expect(FeedbackAttachmentPolicy.formattedSize(3 * mb) == "3 MB")
        #expect(FeedbackAttachmentPolicy.formattedSize(50 * mb) == "50 MB")
        #expect(FeedbackAttachmentPolicy.formattedSize(161 * mb) == "161 MB")
    }

    @Test func `rejections explain themselves`() {
        let rejections: [FeedbackAttachmentRejection] = [
            .unsupportedType(filename: "logs.zip"), .tooLarge(filename: "big.log", limitBytes: 5 * mb),
            .tooMany(limit: 6)
        ]
        for rejection in rejections {
            #expect(!rejection.message.isEmpty)
            #expect(!rejection.message.contains("feedback.attachment"))
        }
        #expect(rejections[0].message.contains("logs.zip"))
        #expect(rejections[1].message.contains("big.log"))
    }

    @Test func `media errors have readable descriptions`() {
        let errors: [FeedbackMediaError] = [
            .videoTooLong(maxMinutes: 10), .videoUnreadable, .compressionFailed("x"),
            .videoStillTooLarge(compressedBytes: 161 * mb)
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.errorDescription?.contains("feedback.attachment") == false)
        }
    }

    @Test func `every language defines the feedback strings`() {
        let keys = [
            "feedback.direct.intro", "feedback.attachment.add", "feedback.attachment.error.tooLarge",
            "feedback.status.rules", "feedback.success.title", "feedback.editor.link.title", "feedback.footer.other"
        ]
        for language in AppLanguage.allCases {
            for key in keys {
                #expect(AppLocalization.shared.string(key, in: language) != key, "\(key) missing in \(language)")
            }
        }
    }
}
