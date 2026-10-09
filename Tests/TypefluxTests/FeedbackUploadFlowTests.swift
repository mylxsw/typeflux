import AppKit
@testable import Typeflux
import XCTest

/// The feedback ticket and PUT share one credential, and an image uploaded
/// under one sign-in is never submitted with another account's feedback.
final class FeedbackUploadFlowTests: XCTestCase {
    func testTicketAndUploadShareOneCredential() async throws {
        let recorder = TokenRecorder()
        let credential = TypefluxCloudSessionCredential(accessToken: "access-a", session: 3)

        let url = try await FeedbackUploadFlow.upload(
            Self.image,
            credential: credential,
            createTarget: { _, token in
                await recorder.record("ticket", token)
                return Self.target
            },
            upload: { _, target, token in
                XCTAssertEqual(target.uploadID, "upload-1")
                await recorder.record("put", token)
            }
        )

        XCTAssertEqual(url, "https://cdn.example/feedback/upload-1.png")
        let calls = await recorder.calls
        XCTAssertEqual(calls, ["ticket:access-a", "put:access-a"])
    }

    func testAnonymousUploadSendsNoToken() async throws {
        let recorder = TokenRecorder()

        _ = try await FeedbackUploadFlow.upload(
            Self.image,
            credential: nil,
            createTarget: { _, token in
                await recorder.record("ticket", token)
                return Self.target
            },
            upload: { _, _, token in await recorder.record("put", token) }
        )

        let calls = await recorder.calls
        XCTAssertEqual(calls, ["ticket:-", "put:-"])
    }

    func testFailedTicketSkipsTheUpload() async {
        let recorder = TokenRecorder()

        do {
            _ = try await FeedbackUploadFlow.upload(
                Self.image,
                credential: nil,
                createTarget: { _, _ in throw FeedbackAPIError.unauthorized },
                upload: { _, _, token in await recorder.record("put", token) }
            )
            XCTFail("Expected the ticket failure")
        } catch {
            XCTAssertEqual(error as? FeedbackAPIError, .unauthorized)
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testCancelledUploadReturnsNoImage() async {
        let gate = Gate()
        let task = Task {
            try await FeedbackUploadFlow.upload(
                Self.image,
                credential: nil,
                createTarget: { _, _ in
                    await gate.wait()
                    return Self.target
                },
                upload: { _, _, _ in XCTFail("A cancelled upload must not PUT") }
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testSubmissionUsesImagesFromTheSameSignIn() throws {
        let images = [
            FeedbackImageAttachment(filename: "a.png", state: .uploaded("https://cdn/a"), uploadOwner: .session(3)),
            FeedbackImageAttachment(filename: "b.png", state: .uploading),
            FeedbackImageAttachment(filename: "c.png", state: .failed("x"))
        ]

        let urls = try FeedbackUploadFlow.submissionImageURLs(for: images, submittingAs: .session(3))

        XCTAssertEqual(urls, ["https://cdn/a"])
    }

    func testSubmissionRefusesImagesFromAnotherSignIn() {
        let stale = FeedbackImageAttachment(filename: "a.png", state: .uploaded("https://cdn/a"), uploadOwner: .session(3))
        let anonymous = FeedbackImageAttachment(filename: "b.png", state: .uploaded("https://cdn/b"), uploadOwner: .anonymous)
        let current = FeedbackImageAttachment(filename: "c.png", state: .uploaded("https://cdn/c"), uploadOwner: .session(4))

        XCTAssertThrowsError(
            try FeedbackUploadFlow.submissionImageURLs(for: [stale, anonymous, current], submittingAs: .session(4))
        ) { error in
            XCTAssertEqual(error as? FeedbackUploadOwnerError, FeedbackUploadOwnerError(staleImageIDs: [stale.id, anonymous.id]))
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        // After logout the account's image cannot go out anonymously either.
        XCTAssertThrowsError(try FeedbackUploadFlow.submissionImageURLs(for: [current], submittingAs: .anonymous))
    }

    func testOwnerFollowsTheCredential() {
        XCTAssertEqual(FeedbackUploadOwner(nil), .anonymous)
        XCTAssertEqual(
            FeedbackUploadOwner(TypefluxCloudSessionCredential(accessToken: "t", session: 9)),
            .session(9)
        )
    }

    // MARK: - Helpers

    private static let image = PreparedFeedbackImage(
        data: Data("png".utf8),
        filename: "screen.png",
        contentType: "image/png",
        thumbnail: NSImage(size: NSSize(width: 1, height: 1))
    )

    private static let target = FeedbackUploadTarget(
        type: FeedbackAPIService.apiProxyUploadType,
        method: "PUT",
        url: "/api/v1/feedback/uploads/upload-1",
        bucket: "feedback",
        region: "auto",
        key: "feedback/upload-1.png",
        expiresAt: 1_777_961_100,
        maxSizeBytes: 5_242_880,
        headers: ["Content-Type": "image/png"],
        fields: [:],
        imageURL: "https://cdn.example/feedback/upload-1.png",
        uploadID: "upload-1",
        issuingAPIBaseURL: URL(string: "https://api.example")
    )
}

private actor TokenRecorder {
    private(set) var calls: [String] = []

    func record(_ step: String, _ token: String?) {
        calls.append("\(step):\(token ?? "-")")
    }
}

private actor Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilEntered() async {
        for _ in 0 ..< 10000 where !entered {
            await Task.yield()
        }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}
