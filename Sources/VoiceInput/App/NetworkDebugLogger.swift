import Foundation
import os

enum NetworkDebugLogger {
    static let logger = Logger(subsystem: "dev.typeflux", category: "Network")

    static func logRequest(_ request: URLRequest, bodyDescription: String? = nil) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<unknown>"
        let headers = redact(headers: request.allHTTPHeaderFields ?? [:])

        let message = """
        [Request]
        URL: \(url)
        Method: \(method)
        Headers: \(headers)
        Body: \(bodyDescription ?? describeBody(request.httpBody))
        """
        logger.info("\(message, privacy: .public)")
    }

    static func logResponse(_ response: URLResponse?, data: Data? = nil, bodyDescription: String? = nil) {
        if let http = response as? HTTPURLResponse {
            let message = """
            [Response]
            URL: \(http.url?.absoluteString ?? "<unknown>")
            Status: \(http.statusCode)
            Headers: \(http.allHeaderFields)
            Body: \(bodyDescription ?? describeBody(data))
            """
            logger.info("\(message, privacy: .public)")
            return
        }

        let message = """
        [Response]
        URL: \(response?.url?.absoluteString ?? "<unknown>")
        Status: <non-http>
        Body: \(bodyDescription ?? describeBody(data))
        """
        logger.info("\(message, privacy: .public)")
    }

    static func logError(context: String, error: Error) {
        let message = "[Error] \(context): \(describe(error: error))"
        logger.error("\(message, privacy: .public)")
        ErrorLogStore.shared.log("[Network] \(message)")
        fputs("Typeflux \(message)\n", stderr)
    }

    static func logMessage(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    private static func redact(headers: [String: String]) -> [String: String] {
        var redacted = headers
        for key in headers.keys {
            if key.caseInsensitiveCompare("Authorization") == .orderedSame {
                redacted[key] = "<redacted>"
            }
        }
        return redacted
    }

    private static func describeBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }

        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
            let string = String(data: pretty, encoding: .utf8)
        {
            return string
        }

        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        return "<\(data.count) bytes binary>"
    }

    static func describe(error: Error) -> String {
        var components: [String] = []
        components.append(error.localizedDescription)
        components.append("type=\(String(reflecting: type(of: error)))")

        let nsError = error as NSError
        components.append("domain=\(nsError.domain)")
        components.append("code=\(nsError.code)")

        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            components.append("reason=\(reason)")
        }

        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            components.append("suggestion=\(suggestion)")
        }

        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            components.append("failingURL=\(failingURL.absoluteString)")
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            components.append(
                "underlying=\(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)"
            )
        }

        let sanitizedUserInfo = sanitize(userInfo: nsError.userInfo)
        if !sanitizedUserInfo.isEmpty {
            components.append("userInfo=\(sanitizedUserInfo)")
        }

        return components.joined(separator: " | ")
    }

    private static func sanitize(userInfo: [String: Any]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in userInfo {
            switch key {
            case NSUnderlyingErrorKey, NSURLErrorFailingURLErrorKey, NSURLErrorFailingURLStringErrorKey:
                continue
            case NSLocalizedDescriptionKey,
                 NSLocalizedFailureReasonErrorKey,
                 NSLocalizedRecoverySuggestionErrorKey:
                sanitized[key] = String(describing: value)
            default:
                if let stringValue = value as? CustomStringConvertible {
                    sanitized[key] = stringValue.description
                }
            }
        }

        return sanitized
    }
}
