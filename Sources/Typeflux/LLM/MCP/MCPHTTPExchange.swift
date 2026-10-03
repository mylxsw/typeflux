import Foundation

enum MCPHTTPTransportError: Error {
    case unauthorized(String?)
    case status(Int)
}

/// One POST and its bounded response stream. A task delegate gives explicit
/// ownership of the URLSessionTask, including cancellation before headers arrive.
final class MCPHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Response = (message: MCPJsonRPCMessage?, http: HTTPURLResponse)
    private let lock = NSLock()
    private let expectedID: MCPMessageId?
    private let receiveMessage: @Sendable (MCPJsonRPCMessage) -> Void
    private let maximumResponseBytes: Int
    private var parser: MCPSSEParser
    private var body = Data()
    private var response: HTTPURLResponse?
    private var isSSE = false
    private var task: URLSessionDataTask?
    private var timer: DispatchWorkItem?
    private var continuation: CheckedContinuation<Response, Error>?
    private var outcome: Result<Response, Error>?

    init(expectedID: MCPMessageId?, maximumResponseBytes: Int,
         receiveMessage: @escaping @Sendable (MCPJsonRPCMessage) -> Void) {
        self.expectedID = expectedID
        self.maximumResponseBytes = maximumResponseBytes
        parser = MCPSSEParser(maximumEventBytes: maximumResponseBytes)
        self.receiveMessage = receiveMessage
    }

    func run(session: URLSession, request: URLRequest, timeout: TimeInterval) async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if let outcome {
                    continuation.resume(with: outcome)
                    return
                }
                self.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = self
                self.task = task
                let timer = DispatchWorkItem { [weak self] in self?.cancel(MCPClientError.timedOut) }
                self.timer = timer
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                task.resume()
            }
        } onCancel: {
            self.cancel(CancellationError())
        }
    }

    func cancel(_ error: Error = CancellationError()) {
        lock.lock()
        defer { lock.unlock() }
        finish(.failure(error))
    }

    /// Called with lock held; exactly one path owns continuation resumption.
    private func finish(_ result: Result<Response, Error>) {
        guard outcome == nil else { return }
        outcome = result
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(MCPClientError.invalidResponse("Non-HTTP response")))
            completionHandler(.cancel)
            return
        }
        self.response = http
        if http.statusCode == 401 {
            finish(.failure(MCPHTTPTransportError.unauthorized(http.value(forHTTPHeaderField: "WWW-Authenticate"))))
        } else if !(200 ..< 300).contains(http.statusCode) {
            finish(.failure(MCPHTTPTransportError.status(http.statusCode)))
        } else if expectedID == nil {
            if http.statusCode == 202 {
                finish(.success((nil, http)))
            } else {
                finish(.failure(MCPClientError.invalidResponse("Expected HTTP 202 for a notification or response")))
            }
        } else {
            let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased()
            isSSE = type == "text/event-stream"
            if !isSSE, type != "application/json" {
                finish(.failure(MCPClientError.invalidResponse("Expected application/json or text/event-stream")))
            }
        }
        completionHandler(outcome == nil ? .allow : .cancel)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        do {
            if isSSE {
                try parser.append(data) { payload in
                    try accept(payload)
                    return outcome == nil
                }
            } else {
                guard body.count + data.count <= maximumResponseBytes else {
                    throw MCPClientError.invalidResponse("JSON response exceeds the size limit")
                }
                body.append(data)
            }
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard outcome == nil else { return }
        if let error {
            finish(.failure(error)); return
        }
        do {
            if !isSSE {
                try accept(body)
            }
            if outcome == nil {
                throw MCPClientError.invalidResponse("Response ended without a matching JSON-RPC result")
            }
        } catch {
            finish(.failure(error))
        }
    }

    private func accept(_ data: Data) throws {
        let message = try JSONDecoder().decode(MCPJsonRPCMessage.self, from: data)
        guard message.jsonrpc == "2.0" else {
            throw MCPClientError.invalidResponse("Unsupported JSON-RPC version")
        }
        if message.method != nil {
            guard message.result == nil, message.error == nil else {
                throw MCPClientError.invalidResponse("JSON-RPC method contains a result or error")
            }
            receiveMessage(message)
            return
        }
        guard message.id == expectedID else { return }
        guard (message.result != nil) != (message.error != nil), let response else {
            throw MCPClientError.invalidResponse("Expected exactly one JSON-RPC result or error")
        }
        if let error = message.error {
            finish(.failure(MCPClientError.serverError(code: error.code, message: error.message)))
        } else {
            finish(.success((message, response)))
        }
    }
}
