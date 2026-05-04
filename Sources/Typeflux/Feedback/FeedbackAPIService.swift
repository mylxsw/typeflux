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
        case .networkError(let message):
            message
        case .serverError(_, let message):
            message ?? L("feedback.error.server")
        case .invalidResponse:
            L("feedback.error.invalidResponse")
        case .unauthorized:
            L("auth.error.unauthorized")
        }
    }
}

struct FeedbackAPIService {
    private static let logger = Logger(subsystem: "ai.gulu.app.typeflux", category: "FeedbackAPIService")

    static func submit(
        content: String,
        contact: String?,
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
            contact: trimmedContact?.isEmpty == false ? trimmedContact : nil
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
            (data, httpResponse) = try await executor.execute { baseURL in
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
        } catch CloudRequestExecutorError.allEndpointsFailed(let lastError) {
            logger.error("Feedback submission failed on all endpoints: \(lastError.localizedDescription)")
            throw FeedbackAPIError.networkError(lastError.localizedDescription)
        } catch {
            logger.error("Feedback submission network error: \(error.localizedDescription)")
            throw FeedbackAPIError.networkError(error.localizedDescription)
        }

        let envelope: APIResponse<FeedbackSubmissionResponse>
        do {
            envelope = try JSONDecoder().decode(APIResponse<FeedbackSubmissionResponse>.self, from: data)
        } catch {
            logger.error("Feedback response decoding error: \(error.localizedDescription)")
            throw FeedbackAPIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw FeedbackAPIError.unauthorized
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
}
