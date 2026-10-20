import AppKit
import Foundation
import Testing
@testable import Typeflux

/// Scripted services for the feedback window: results and failures are set per test.
final class FeedbackServicesStub: FeedbackServicing, @unchecked Sendable {
    struct Submission: Equatable {
        let content: String
        let contact: String?
        let attachments: [FeedbackAttachmentPayload]
    }

    private let lock = NSLock()
    private var _submissions: [Submission] = []
    private var _uploads: [String] = []
    var credentialValue: TypefluxCloudSessionCredential?
    var imageBytes = 1000
    var videoError: Error?
    var uploadError: Error?
    var submitError: Error?
    var holdUpload = false
    var submitDelayNanoseconds: UInt64 = 0

    var submissions: [Submission] {
        lock.withLock { _submissions }
    }

    var uploads: [String] {
        lock.withLock { _uploads }
    }

    func credential() async -> TypefluxCloudSessionCredential? {
        credentialValue
    }

    func prepareImage(data _: Data, filename: String) async throws -> PreparedFeedbackFile {
        PreparedFeedbackFile(
            data: Data(count: imageBytes),
            filename: (filename as NSString).deletingPathExtension + ".jpg",
            contentType: "image/jpeg", kind: .image, thumbnail: NSImage(size: NSSize(width: 40, height: 30))
        )
    }

    func prepareVideo(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedFeedbackFile {
        progress(0.5)
        if let videoError {
            throw videoError
        }
        return PreparedFeedbackFile(
            data: Data(count: 2000), filename: url.deletingPathExtension().lastPathComponent + ".mp4",
            contentType: "video/mp4", kind: .video, thumbnail: nil, durationSeconds: 12
        )
    }

    func upload(_ file: PreparedFeedbackFile, credential _: TypefluxCloudSessionCredential?) async throws -> String {
        if holdUpload {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if let uploadError {
            throw uploadError
        }
        lock.withLock { _uploads.append(file.filename) }
        return "https://cdn.example/\(file.filename)"
    }

    func submit(
        content: String, contact: String?, attachments: [FeedbackAttachmentPayload],
        credential _: TypefluxCloudSessionCredential?
    ) async throws {
        if submitDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: submitDelayNanoseconds)
        }
        if let submitError {
            throw submitError
        }
        lock.withLock { _submissions.append(Submission(content: content, contact: contact, attachments: attachments)) }
    }
}

@Suite(.serialized, .exclusiveUIState)
@MainActor
struct FeedbackWindowModelTests {
    private struct Fixture {
        let model: FeedbackWindowModel
        let services: FeedbackServicesStub
        let textView: FeedbackTextView
        let directory: URL
    }

    private func makeFixture(email: String = "me@example.com") throws -> Fixture {
        let services = FeedbackServicesStub()
        let model = FeedbackWindowModel(services: services, defaultContact: { email })
        let textView = FeedbackTextView()
        model.editor.textView = textView
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(model: model, services: services, textView: textView, directory: directory)
    }

    private func file(_ name: String, bytes: Int, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func type(_ text: String, in fixture: Fixture) {
        fixture.textView.insertText(text, replacementRange: fixture.textView.selectedRange())
        fixture.model.editorDidChange()
    }

    private func settle(_: FeedbackWindowModel, until done: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 400 where !done() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(done())
    }

    @Test func `contact defaults to the account email and text enables submit`() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(fixture.model.contact == "me@example.com")
        #expect(!fixture.model.canSubmit && !fixture.model.hasDraft)
        type("   ", in: fixture)
        #expect(!fixture.model.hasText)
        type("It crashes", in: fixture)
        #expect(fixture.model.hasText && fixture.model.canSubmit && fixture.model.hasDraft)
    }

    @Test func `an image is compressed, uploaded and placed in the body`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let url = try file("shot.png", bytes: 50, in: fixture.directory)
        type("see below", in: fixture)

        fixture.model.addFiles([url])
        #expect(fixture.model.attachments.count == 1)
        #expect(fixture.model.attachments[0].state.isInProgress)
        #expect(!fixture.model.canSubmit, "submit waits for the upload")
        #expect(fixture.textView.attachmentIDs == fixture.model.attachments.map(\.id))

        try await settle(fixture.model) { fixture.model.attachments.first?.state.isReady == true }
        let attachment = try #require(fixture.model.attachments.first)
        #expect(attachment.filename == "shot.jpg" && attachment.sizeBytes == 1000)
        #expect(attachment.state.uploadedURL == "https://cdn.example/shot.jpg")
        #expect(fixture.model.canSubmit)
        #expect(fixture.model.previewURL(id: attachment.id) == url)

        fixture.model.submit()
        try await settle(fixture.model) { fixture.model.phase == .submitted }
        let submission = try #require(fixture.services.submissions.first)
        #expect(submission.content == "see below\n\n![shot.jpg](https://cdn.example/shot.jpg)")
        #expect(submission.contact == "me@example.com")
        #expect(submission.attachments.map(\.kind) == ["image"])
        #expect(fixture.model.submittedContact == "me@example.com")
        #expect(!fixture.model.hasDraft, "a submitted draft is dropped")
    }

    @Test func `videos report progress and keep their duration`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try fixture.model.addFiles([file("rec.mov", bytes: 10, in: fixture.directory)])
        try await settle(fixture.model) { fixture.model.attachments.first?.state.isReady == true }
        let video = try #require(fixture.model.attachments.first)
        #expect(video.kind == .video && video.contentType == "video/mp4" && video.durationSeconds == 12)
        #expect(video.filename == "rec.mp4")
    }

    @Test func `text files are uploaded unchanged and oversized ones are refused`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let small = try file("app.log", bytes: 100, in: fixture.directory)
        let big = try file("huge.log", bytes: 5 * 1024 * 1024 + 1, in: fixture.directory)
        let zip = try file("a.zip", bytes: 10, in: fixture.directory)

        fixture.model.addFiles([small])
        try await settle(fixture.model) { fixture.model.attachments.first?.state.isReady == true }
        #expect(fixture.model.attachments[0].contentType == "text/plain")

        fixture.model.addFiles([big])
        #expect(fixture.model.attachments.count == 1)
        #expect(fixture.model.notice?.contains("huge.log") == true)
        fixture.model.addFiles([zip])
        #expect(fixture.model.attachments.count == 1)
        #expect(fixture.model.notice?.contains("a.zip") == true)
    }

    @Test func `a video still too large after compression stays and blocks submit`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.videoError = FeedbackMediaError.videoStillTooLarge(compressedBytes: 161 * 1024 * 1024)
        type("video", in: fixture)
        try fixture.model.addFiles([file("long.mov", bytes: 10, in: fixture.directory)])
        try await settle(fixture.model) {
            if case .rejected = fixture.model.attachments.first?.state {
                true
            } else {
                false
            }
        }
        #expect(!fixture.model.canSubmit)
        #expect(fixture.model.statusLine == L("feedback.status.rejected"))
        #expect(fixture.model.isStatusLineWarning)
        let id = fixture.model.attachments[0].id
        fixture.model.remove(id: id)
        #expect(fixture.model.attachments.isEmpty && fixture.textView.attachmentIDs.isEmpty)
        #expect(fixture.model.canSubmit)
        #expect(!fixture.model.isStatusLineWarning)
    }

    @Test func `an oversized compressed image is rejected`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.imageBytes = 4 * 1024 * 1024
        fixture.model.addImageData(Data([1]), filename: "big.png")
        try await settle(fixture.model) {
            if case .rejected = fixture.model.attachments.first?.state {
                true
            } else {
                false
            }
        }
        #expect(fixture.services.uploads.isEmpty)
    }

    @Test func `a failed upload can be retried`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.uploadError = FeedbackAPIError.networkError("offline")
        try fixture.model.addFiles([file("a.log", bytes: 10, in: fixture.directory)])
        try await settle(fixture.model) {
            if case .failed = fixture.model.attachments.first?.state {
                true
            } else {
                false
            }
        }
        #expect(fixture.model.statusLine.contains("a.log"))
        #expect(fixture.model.isStatusLineWarning)
        #expect(!fixture.model.canSubmit)

        fixture.services.uploadError = nil
        fixture.model.retry(id: fixture.model.attachments[0].id)
        try await settle(fixture.model) { fixture.model.attachments.first?.state.isReady == true }
    }

    @Test func `no more than six attachments`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let urls = try (0 ..< 8).map { try file("f\($0).txt", bytes: 5, in: fixture.directory) }
        fixture.model.addFiles(urls)
        #expect(fixture.model.attachments.count == 6)
        #expect(!fixture.model.canAddAttachments)
        #expect(fixture.model.attachmentCountText == "6/6")
        #expect(fixture.model.notice == FeedbackAttachmentRejection.tooMany(limit: 6).message)
        fixture.model.addImageData(Data([1]), filename: "x.png")
        #expect(fixture.model.attachments.count == 6)
        try await settle(fixture.model) { fixture.model.attachments.allSatisfy(\.state.isReady) }
    }

    @Test func `deleting a block in the editor drops the attachment and its upload`() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.holdUpload = true
        try fixture.model.addFiles([file("a.log", bytes: 10, in: fixture.directory)])
        let id = try #require(fixture.model.attachments.first?.id)
        fixture.textView.removeAttachmentBlock(id: id)
        fixture.model.editorDidChange()
        #expect(fixture.model.attachments.isEmpty)
    }

    @Test func `an attachment the model does not know is removed from the editor`() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.textView.insertAttachmentBlock(FeedbackTextAttachment(attachmentID: UUID()))
        fixture.model.editorDidChange()
        #expect(fixture.textView.attachmentIDs.isEmpty)
    }

    @Test func `a failed submission keeps the draft and shows the error`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.submitError = FeedbackAPIError.networkError("no network")
        type("hello", in: fixture)
        fixture.model.submit()
        try await settle(fixture.model) { fixture.model.errorMessage != nil }
        #expect(fixture.model.errorMessage == "no network")
        #expect(!fixture.model.isSubmitting && fixture.model.phase == .editing && fixture.model.hasText)
        type(" more", in: fixture)
        #expect(fixture.model.errorMessage == nil, "editing clears the error")
    }

    @Test func `uploads from another sign-in are refused at submit`() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.services.credentialValue = TypefluxCloudSessionCredential(accessToken: "t", session: 1)
        type("hello", in: fixture)
        try fixture.model.addFiles([file("a.log", bytes: 10, in: fixture.directory)])
        try await settle(fixture.model) { fixture.model.attachments.first?.state.isReady == true }

        fixture.services.credentialValue = TypefluxCloudSessionCredential(accessToken: "u", session: 2)
        fixture.model.submit()
        try await settle(fixture.model) { fixture.model.errorMessage != nil }
        #expect(fixture.services.submissions.isEmpty)
        if case .failed = fixture.model.attachments[0].state {}
        else {
            Issue.record("expected the stale upload to fail")
        }
    }

    @Test func `closing and reopening keeps the draft until it is cleared`() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.model.windowWillShow()
        #expect(!fixture.model.isDraftRestored)
        type("half written", in: fixture)
        fixture.model.contact = "other@example.com"
        fixture.model.windowWillShow()
        #expect(fixture.model.isDraftRestored && fixture.model.contact == "other@example.com")
        fixture.model.reset()
        #expect(!fixture.model.hasDraft && fixture.model.contact == "me@example.com")
        #expect(fixture.textView.string.isEmpty)
    }

    @Test func `an empty contact is not sent`() async throws {
        let fixture = try makeFixture(email: "")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        type("hello", in: fixture)
        fixture.model.contact = "  "
        fixture.model.submit()
        try await settle(fixture.model) { fixture.model.phase == .submitted }
        #expect(fixture.services.submissions.first?.contact == nil)
        #expect(fixture.model.submittedContact == nil)
        fixture.model.windowWillShow()
        #expect(fixture.model.phase == .editing, "a submitted window opens as a new form")
    }
}
