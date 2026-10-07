import Foundation
@testable import Typeflux
import XCTest

private final class ImageHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url!.lastPathComponent
        if path == "failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status = Int(path) ?? 200
        let headers = path == "length" ? ["Content-Length": "999999"] : [:]
        let response: URLResponse = path == "nonhttp"
            ? URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            : HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "stream" {
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 20000))
        } else {
            client?.urlProtocol(self, didLoad: Data("image".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AskImageHTTPTests: XCTestCase {
    private var transport: AskImageHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageHTTPProtocol.self]
        return .init(configuration: configuration)
    }

    func testBoundedHTTPResponsesAndSanitizedErrors() async throws {
        let data = try await transport.send(
            URLRequest(url: XCTUnwrap(URL(string: "https://image.test/success"))),
            limit: 5
        )
        XCTAssertEqual(data, Data("image".utf8))
        for (path, expected) in [("401", AskImageError.http(401)), ("429", .http(429)), ("500", .http(500)),
                                 ("302", .http(302)), ("length", .tooLarge), ("stream", .tooLarge), (
                                     "nonhttp",
                                     .invalidResponse
                                 )] {
            do {
                _ = try await transport.send(URLRequest(url: URL(string: "https://image.test/" + path)!), limit: 17000)
                XCTFail(path)
            } catch { XCTAssertEqual(error as? AskImageError, expected, path) }
        }
        do {
            _ = try await transport.send(
                URLRequest(url: XCTUnwrap(URL(string: "https://image.test/failure"))),
                limit: 100
            )
            XCTFail()
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testRedirectNeverForwardsCredentialsAndCancellationStopsReading() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = try URLRequest(url: XCTUnwrap(URL(string: "https://other.test/image")))
        let task = session.dataTask(with: request)
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(request.url),
            statusCode: 302,
            httpVersion: nil,
            headerFields: [:]
        ))
        AskImageRedirectPolicy().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        ) {
            XCTAssertNil($0)
        }
        let operation = Task {
            try await transport.send(URLRequest(url: URL(string: "https://image.test/stream")!), limit: 30000)
        }
        operation.cancel()
        do { _ = try await operation.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
}
