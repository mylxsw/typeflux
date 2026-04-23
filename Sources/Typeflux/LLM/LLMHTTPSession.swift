import Foundation

/// Shared URLSession configured for LLM HTTP requests.
/// Leaves request timeout at the system default so long-running completions
/// and sparse SSE streams are not terminated prematurely.
enum LLMHTTPSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()
}
