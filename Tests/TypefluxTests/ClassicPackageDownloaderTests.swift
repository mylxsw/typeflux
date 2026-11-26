@testable import Typeflux
import XCTest

/// Serves canned responses to the download session. `hang` never finishes, so the test can cancel.
private final class ClassicDownloadStubProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior { case respond(status: Int, body: Data), fail, hang }
    nonisolated(unsafe) static var behavior: Behavior = .respond(status: 200, body: Data())

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.behavior {
        case let .respond(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let half = body.count / 2
            client?.urlProtocol(self, didLoad: body.prefix(half))
            client?.urlProtocol(self, didLoad: body.suffix(from: half))
            client?.urlProtocolDidFinishLoading(self)
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hang:
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "1000"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }

    override func stopLoading() {}
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double?] = []
    var values: [Double?] { lock.withLock { stored } }
    func append(_ value: Double?) { lock.withLock { stored.append(value) } }
}

final class ClassicPackageDownloaderTests: XCTestCase {
    private let url = URL(string: "https://downloads.example.com/classic.zip")!

    private func makeDownloader() -> URLSessionClassicPackageDownloader {
        URLSessionClassicPackageDownloader(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ClassicDownloadStubProtocol.self]
            return configuration
        })
    }

    func testDownloadsToACallerOwnedFileAndReportsProgress() async throws {
        let body = Data((0 ..< 4096).map { UInt8($0 % 251) })
        ClassicDownloadStubProtocol.behavior = .respond(status: 200, body: body)
        let progress = ProgressRecorder()

        let file = try await makeDownloader().download(from: url) { progress.append($0) }
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(file.pathExtension, "zip")
        XCTAssertTrue(progress.values.contains { $0 == nil }, "starts indeterminate")
        XCTAssertEqual(progress.values.compactMap { $0 }.last, 1)
    }

    func testHTTPErrorStatusFailsTheDownload() async {
        ClassicDownloadStubProtocol.behavior = .respond(status: 404, body: Data("missing".utf8))
        do {
            _ = try await makeDownloader().download(from: url) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ClassicPackageDownloadError, .httpStatus(404))
            XCTAssertNotNil((error as? ClassicPackageDownloadError)?.errorDescription)
        }
    }

    func testTransportErrorIsReported() async {
        ClassicDownloadStubProtocol.behavior = .fail
        do {
            _ = try await makeDownloader().download(from: url) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testCancellingTheTaskCancelsTheTransfer() async {
        ClassicDownloadStubProtocol.behavior = .hang
        let downloader = makeDownloader()
        let url = url
        let task = Task { try await downloader.download(from: url) { _ in } }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testCancellingBeforeStartNeverStartsTheTransfer() async {
        ClassicDownloadStubProtocol.behavior = .hang
        let downloader = makeDownloader()
        let url = url
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await downloader.download(from: url) { _ in }
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
