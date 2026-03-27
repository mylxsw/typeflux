import Foundation
import os

enum NetworkDebugLogger {
    static let logger = Logger(subsystem: "dev.voiceinput", category: "Network")

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
        let message = "[Error] \(context): \(error.localizedDescription)"
        logger.error("\(message, privacy: .public)")
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
}
