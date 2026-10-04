import Foundation

public enum ChatAPIError: Error, Equatable {
    case unauthorized
    case server(code: String, message: String?)
    case invalidResponse
    case unavailable
}

public struct ChatAPIEnvelope<Value: Decodable>: Decodable {
    public let code: String
    public let message: String?
    public let data: Value?
}

/// Stateless request/envelope handling. Desktop keeps endpoint failover and its
/// own authentication UI while sharing the wire contract with mobile.
public enum ChatRequest {
    public static let conversationsPath = "/api/v1/ask/conversations"

    public static func resolve(baseURL: URL, path: String) -> URL {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/" + trimmedPath : "/" + basePath + "/" + trimmedPath
        return components.url ?? baseURL
    }

    public static func make(baseURL: URL, path: String, method: String = "GET", body: Data? = nil,
                            token: String? = nil, timeout: TimeInterval = 200,
                            headers: [String: String] = [:]) -> URLRequest {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let resolvedURL = resolve(baseURL: baseURL, path: String(pieces[0]))
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        // API paths can already contain escaped opaque IDs. Setting .path here
        // would escape their percent signs a second time (for example %2F -> %252F).
        var rawPath = URLComponents()
        rawPath.path = String(pieces[0])
        let encodedPath = URLComponents(string: String(pieces[0]))?.percentEncodedPath ?? rawPath.percentEncodedPath
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = encodedPath.hasPrefix("/") ? String(encodedPath.dropFirst()) : encodedPath
        components.percentEncodedPath = prefix.isEmpty ? "/" + suffix : "/" + prefix + "/" + suffix
        if pieces.count == 2 { components.percentEncodedQuery = String(pieces[1]) }
        var request = URLRequest(url: components.url ?? resolvedURL)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    public static func decode<Value: Decodable>(_ type: Value.Type = Value.self, data: Data,
                                                statusCode: Int, decoder: JSONDecoder = ChatCoding.decoder()) throws -> Value {
        if statusCode == 401 { throw ChatAPIError.unauthorized }
        let envelope: ChatAPIEnvelope<Value>
        do { envelope = try decoder.decode(ChatAPIEnvelope<Value>.self, from: data) }
        catch { throw ChatAPIError.invalidResponse }
        guard (200..<300).contains(statusCode), envelope.code == "OK", let value = envelope.data else {
            throw ChatAPIError.server(code: envelope.code, message: envelope.message)
        }
        return value
    }

    /// Encode an opaque identifier as exactly one URL path component.
    public static func pathComponent(_ id: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if id == "." || id == ".." { return id.replacingOccurrences(of: ".", with: "%2E") }
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
