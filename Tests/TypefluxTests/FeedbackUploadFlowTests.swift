import AppKit
@testable import Typeflux
import XCTest

/// The feedback ticket and PUT share one credential, and an image uploaded
/// under one sign-in is never submitted with another account's feedback.
final class FeedbackUploadFlowTests: XCTestCase {
    func testTicketAndUploadShareOneCredential() async throws {
        let session = UploadStubSession()
        let credential = TypefluxCloudSessionCredential(accessToken: "access-a", session: 3)

        let url = try await FeedbackUploadFlow.upload(
            Self.image, credential: credential, executor: Self.executor(session), session: session
        )

        XCTAssertEqual(url, "https://cdn.example/feedback/upload-1.png")
        let requests = await session.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v1/feedback/uploads/presign", "/api/v1/feedback/uploads/upload-1"])
        XCTAssertEqual(requests.map(\.authorization), ["Bearer access-a", "Bearer access-a"])
    }

    func testAnonymousUploadSendsNoToken() async throws {
        let session = UploadStubSession()

        _ = try await FeedbackUploadFlow.upload(
            Self.image, credential: nil, executor: Self.executor(session), session: session
        )

        let requests = await session.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.authorization), [nil, nil])
    }

    func testFailedTicketSkipsTheUpload() async {
        let session = UploadStubSession(presignStatus: 401)

        do {
            _ = try await FeedbackUploadFlow.upload(
                Self.image, credential: nil, executor: Self.executor(session), session: session
            )
            XCTFail("Expected the ticket failure")
        } catch {
            XCTAssertEqual(error as? FeedbackAPIError, .unauthorized)
        }
        let requests = await session.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v1/feedback/uploads/presign"])
    }

    func testCancelledUploadReturnsNoImage() async {
        let session = UploadStubSession(holdPresign: true)
        let task = Task {
            try await FeedbackUploadFlow.upload(
                Self.image, credential: nil, executor: Self.executor(session), session: session
            )
        }
        await session.waitUntilHolding()
        task.cancel()
        await session.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await session.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v1/feedback/uploads/presign"], "a cancelled upload must not PUT")
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
        let stale = Self.uploaded("a", owner: .session(3))
        let anonymous = Self.uploaded("b", owner: .anonymous)
        let current = Self.uploaded("c", owner: .session(4))

        XCTAssertThrowsError(
            try FeedbackUploadFlow.submissionImageURLs(for: [stale, anonymous, current], submittingAs: .session(4))
        ) { error in
            let expected = FeedbackUploadOwnerError(staleImageIDs: [stale.id, anonymous.id])
            XCTAssertEqual(error as? FeedbackUploadOwnerError, expected)
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

    private static func uploaded(_ name: String, owner: FeedbackUploadOwner) -> FeedbackImageAttachment {
        FeedbackImageAttachment(filename: "\(name).png", state: .uploaded("https://cdn/\(name)"), uploadOwner: owner)
    }

    private static func executor(_ session: UploadStubSession) -> CloudRequestExecutor {
        CloudRequestExecutor(
            selector: CloudEndpointSelector(
                baseURLs: [URL(string: "https://api.example")!],
                prober: UploadNoOpProber()
            ),
            session: session
        )
    }
}

/// Answers the presign request with a relative ticket and the PUT with 204,
/// recording the path and authorization of each request.
private actor UploadStubSession: CloudHTTPSession {
    struct Request: Equatable {
        let path: String
        let authorization: String?
    }

    private let presignStatus: Int
    private let holdPresign: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var holding = false
    private(set) var requests: [Request] = []

    init(presignStatus: Int = 200, holdPresign: Bool = false) {
        self.presignStatus = presignStatus
        self.holdPresign = holdPresign
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        requests.append(Request(path: url.path, authorization: request.value(forHTTPHeaderField: "Authorization")))
        if url.path.hasSuffix("/presign") {
            if holdPresign {
                await withCheckedContinuation { continuation in
                    held = continuation
                    holding = true
                }
            }
            let body = presignStatus == 200 ? Self.ticket : Data()
            return (body, HTTPURLResponse(url: url, statusCode: presignStatus, httpVersion: nil, headerFields: nil)!)
        }
        return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
    }

    func waitUntilHolding() async {
        for _ in 0 ..< 10000 where !holding {
            await Task.yield()
        }
    }

    func release() {
        held?.resume()
        held = nil
    }

    private static let ticket = Data("""
    {"code":"OK","data":{"type":"bounded_proxy_put","method":"PUT","url":"/api/v1/feedback/uploads/upload-1",\
    "bucket":"feedback","region":"auto","key":"feedback/upload-1.png","expires_at":1777961100,\
    "max_size_bytes":5242880,"headers":{"Content-Type":"image/png"},"fields":{},\
    "image_url":"https://cdn.example/feedback/upload-1.png","upload_id":"upload-1"}}
    """.utf8)
}

private struct UploadNoOpProber: CloudEndpointProbing {
    func probe(baseURL _: URL, nonce _: String, timeout _: TimeInterval) async throws -> CloudEndpointProbeResult {
        CloudEndpointProbeResult(latencyMs: 1, serverID: nil, serverVersion: nil, nonceMatches: true)
    }
}
