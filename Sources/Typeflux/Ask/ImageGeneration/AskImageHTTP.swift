import Foundation

protocol AskImageTransport: Sendable {
    func send(_ request: URLRequest, limit: Int) async throws -> Data
}

/// Each operation has a bounded response, no cookies, no redirects and no automatic retries.
struct AskImageHTTP: AskImageTransport {
    var configuration: URLSessionConfiguration = .ephemeral

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: AskImageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw AskImageError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw AskImageError.http(response.statusCode) }
        guard response.expectedContentLength <= limit else { throw AskImageError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count % 16384 == 0 {
                try Task.checkCancellation()
            }
            guard data.count < limit else { throw AskImageError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

final class AskImageRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
