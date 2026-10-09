import Foundation
import os

struct CreateFeedbackRequest: Encodable, Equatable {
    let content: String
    let contact: String?
    let imageURLs: [String]

    init(content: String, contact: String? = nil, imageURLs: [String] = []) {
        self.content = content
        self.contact = contact
        self.imageURLs = imageURLs
    }

    enum CodingKeys: String, CodingKey {
        case content, contact
        case imageURLs = "image_urls"
    }
}

struct FeedbackSubmissionResponse: Decodable, Equatable {
    let id: String
    let status: String
}

struct FeedbackUploadPresignRequest: Encodable, Equatable {
    let filename: String
    let contentType: String
    let sizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case sizeBytes = "size_bytes"
    }
}

struct FeedbackUploadTarget: Decodable, Equatable {
    let type: String
    let method: String
    let url: String
    let bucket: String
    let region: String
    let key: String
    let expiresAt: Int64
    let maxSizeBytes: Int64
    let headers: [String: String]
    let fields: [String: String]
    let imageURL: String
    let uploadID: String
    /// Base URL of the API endpoint that issued this target. Relative upload
    /// URLs resolve against it, and only this origin receives the bearer token.
    var issuingAPIBaseURL: URL?

    enum CodingKeys: String, CodingKey {
        case type, method, url, bucket, region, key, headers, fields
        case expiresAt = "expires_at"
        case maxSizeBytes = "max_size_bytes"
        case imageURL = "image_url"
        case uploadID = "upload_id"
    }
}

enum FeedbackAPIError: LocalizedError, Equatable {
    case emptyContent
    case networkError(String)
    case serverError(code: String, message: String?)
    case invalidResponse
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            L("feedback.error.emptyContent")
        case let .networkError(message):
            message
        case let .serverError(code, message):
            TypefluxCloudServerErrorMessage.userMessage(
                code: code,
                message: message,
                fallback: L("feedback.error.server")
            )
        case .invalidResponse:
            L("feedback.error.invalidResponse")
        case .unauthorized:
            L("auth.error.unauthorized")
        }
    }
}

enum FeedbackAPIService {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "FeedbackAPIService")

    static func submit(
        content: String,
        contact: String?,
        imageURLs: [String] = [],
        token: String? = nil,
        executor: CloudRequestExecutor = CloudRequestExecutor()
    ) async throws -> FeedbackSubmissionResponse {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw FeedbackAPIError.emptyContent
        }

        let trimmedContact = contact?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CreateFeedbackRequest(
            content: trimmedContent,
            contact: trimmedContact?.isEmpty == false ? trimmedContact : nil,
            imageURLs: imageURLs
        )
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await executor.execute(apiPath: "/api/v1/feedback") { baseURL in
                let url = AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/feedback")
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token, !token.isEmpty {
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                urlRequest.httpBody = payload
                urlRequest.timeoutInterval = 30
                return urlRequest
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let CloudRequestExecutorError.allEndpointsFailed(lastError) {
            logger.error("Feedback submission failed on all endpoints: \(lastError.localizedDescription)")
            throw FeedbackAPIError.networkError(lastError.localizedDescription)
        } catch {
            logger.error("Feedback submission network error: \(error.localizedDescription)")
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }

        if httpResponse.statusCode == 401 {
            throw FeedbackAPIError.unauthorized
        }

        let envelope: APIResponse<FeedbackSubmissionResponse>
        do {
            envelope = try JSONDecoder().decode(APIResponse<FeedbackSubmissionResponse>.self, from: data)
        } catch {
            logger.error(
                "Feedback response decoding error for HTTP \(httpResponse.statusCode, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            if !(200 ..< 300).contains(httpResponse.statusCode) {
                throw FeedbackAPIError.serverError(code: "HTTP_\(httpResponse.statusCode)", message: nil)
            }
            throw FeedbackAPIError.invalidResponse
        }

        guard httpResponse.statusCode >= 200, httpResponse.statusCode < 300,
              envelope.code == "OK",
              let responseData = envelope.data
        else {
            logger.error("Feedback submission failed with HTTP \(httpResponse.statusCode, privacy: .public)")
            throw FeedbackAPIError.serverError(code: envelope.code, message: envelope.message)
        }

        return responseData
    }

    static func createImageUploadTarget(
        filename: String,
        contentType: String,
        sizeBytes: Int64,
        token: String? = nil,
        executor: CloudRequestExecutor = CloudRequestExecutor()
    ) async throws -> FeedbackUploadTarget {
        let request = FeedbackUploadPresignRequest(
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes
        )

        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }

        let data: Data
        let httpResponse: HTTPURLResponse
        let issuingBaseURL = IssuingBaseURLRecorder()
        do {
            (data, httpResponse) = try await executor.execute(apiPath: "/api/v1/feedback/uploads/presign") { baseURL in
                issuingBaseURL.record(baseURL)
                let url = AuthEndpointResolver.resolve(baseURL: baseURL, path: "/api/v1/feedback/uploads/presign")
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token, !token.isEmpty {
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                urlRequest.httpBody = payload
                urlRequest.timeoutInterval = 30
                return urlRequest
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let CloudRequestExecutorError.allEndpointsFailed(lastError) {
            logger.error("Feedback upload presign failed on all endpoints: \(lastError.localizedDescription)")
            throw FeedbackAPIError.networkError(lastError.localizedDescription)
        } catch {
            logger.error("Feedback upload presign network error: \(error.localizedDescription)")
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }

        if httpResponse.statusCode == 401 {
            throw FeedbackAPIError.unauthorized
        }

        let envelope: APIResponse<FeedbackUploadTarget>
        do {
            envelope = try JSONDecoder().decode(APIResponse<FeedbackUploadTarget>.self, from: data)
        } catch {
            logger.error(
                "Feedback upload presign decoding error for HTTP \(httpResponse.statusCode, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            if !(200 ..< 300).contains(httpResponse.statusCode) {
                throw FeedbackAPIError.serverError(code: "HTTP_\(httpResponse.statusCode)", message: nil)
            }
            throw FeedbackAPIError.invalidResponse
        }

        guard httpResponse.statusCode >= 200, httpResponse.statusCode < 300,
              envelope.code == "OK",
              let responseData = envelope.data
        else {
            logger.error("Feedback upload presign failed with HTTP \(httpResponse.statusCode, privacy: .public)")
            throw FeedbackAPIError.serverError(code: envelope.code, message: envelope.message)
        }

        var target = responseData
        target.issuingAPIBaseURL = issuingBaseURL.value
        return target
    }

    /// Resolves the upload URL and decides whether it may carry the account
    /// bearer token. API upload targets may be relative and must stay on the
    /// issuing API origin; legacy presigned storage URLs are absolute HTTPS
    /// URLs on another host and never receive the token.
    static func resolveUploadURL(for target: FeedbackUploadTarget) throws -> (url: URL, isAPIOrigin: Bool) {
        let apiBaseURL = target.issuingAPIBaseURL
        guard let url = URL(string: target.url, relativeTo: apiBaseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host?.isEmpty == false
        else {
            throw FeedbackAPIError.invalidResponse
        }
        if let apiBaseURL, isSameOrigin(url, apiBaseURL) {
            return (url, true)
        }
        // Only an absolute storage URL may leave the API origin, and only over
        // HTTPS. A proxy target must never point elsewhere.
        guard URL(string: target.url)?.scheme != nil,
              scheme == "https",
              target.type != apiProxyUploadType
        else {
            throw FeedbackAPIError.invalidResponse
        }
        return (url, false)
    }

    static let apiProxyUploadType = "bounded_proxy_put"

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    static func uploadImage(
        data: Data,
        filename: String,
        contentType: String,
        to target: FeedbackUploadTarget,
        token: String? = nil,
        session: CloudHTTPSession = URLSession.shared
    ) async throws {
        let (url, isAPIOrigin) = try resolveUploadURL(for: target)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = target.method.isEmpty ? "POST" : target.method
        request.timeoutInterval = 60
        for (name, value) in target.headers where name.caseInsensitiveCompare("Authorization") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if isAPIOrigin, let token, !token.isEmpty {
            // The API checks the same account on the ticket, the PUT and the
            // feedback submission.
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if request.httpMethod?.uppercased() == "PUT" {
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            request.httpBody = data
        } else {
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let fieldParts = target.fields
                .sorted { $0.key < $1.key }
                .map { MultipartPart.text(name: $0.key, value: $0.value) }
            request.httpBody = try MultipartFormData.build(
                boundary: boundary,
                parts: fieldParts + [.fileData(name: "file", filename: filename, mimeType: contentType, data: data)]
            )
        }
        try Task.checkCancellation()

        do {
            let (responseData, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FeedbackAPIError.invalidResponse
            }
            if isAPIOrigin, httpResponse.statusCode == 401 {
                throw FeedbackAPIError.unauthorized
            }
            guard httpResponse.statusCode >= 200, httpResponse.statusCode < 300 else {
                let responseBody = uploadFailureResponseBody(responseData)
                let message = responseBody.isEmpty
                    ? "HTTP \(httpResponse.statusCode)"
                    : "HTTP \(httpResponse.statusCode): \(responseBody)"
                logger.error(
                    "Feedback image upload failed with HTTP \(httpResponse.statusCode, privacy: .public): \(responseBody, privacy: .public)"
                )
                throw FeedbackAPIError.serverError(code: "UPLOAD_FAILED", message: message)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as FeedbackAPIError {
            throw error
        } catch {
            logger.error("Feedback image upload failed: \(error.localizedDescription)")
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }
    }

    private static func uploadFailureResponseBody(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let body = String(data: data, encoding: .utf8) {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "<\(data.count) bytes binary>"
    }
}

/// Remembers the endpoint of the most recent attempt made by
/// `CloudRequestExecutor`; attempts run sequentially, so the last recorded
/// base URL issued the response that was returned.
private final class IssuingBaseURLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var baseURL: URL?

    func record(_ url: URL) {
        lock.lock()
        baseURL = url
        lock.unlock()
    }

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return baseURL
    }
}
