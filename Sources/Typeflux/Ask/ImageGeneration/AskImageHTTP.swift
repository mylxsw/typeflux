import Foundation

protocol AskImageTransport: Sendable {
    func send(_ request: URLRequest, limit: Int) async throws -> Data
}

/// Each operation has a bounded response, no cookies and no automatic retries. Redirects are opt-in for public image GETs only.
struct AskImageHTTP: AskImageTransport {
    var configuration: URLSessionConfiguration = .ephemeral
    var maximumRedirects = 0

    func send(_ request: URLRequest, limit: Int) async throws -> Data {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: config, delegate: AskImageRedirectPolicy(maximumRedirects: maximumRedirects), delegateQueue: nil)
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
    private var remaining: Int
    init(maximumRedirects: Int = 0) { remaining = min(3, max(0, maximumRedirects)) }
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard remaining > 0, request.httpMethod == "GET", let url = request.url,
              url.absoluteString.utf8.count <= 16 * 1024,
              AskGeneratedImage(assetId: "redirect", url: url.absoluteString).safeURL != nil else {
            completionHandler(nil); return
        }
        remaining -= 1
        // Construct a fresh request: never forward authorization, cookies or provider headers.
        var clean = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        clean.httpMethod = "GET"
        completionHandler(clean)
    }
}
