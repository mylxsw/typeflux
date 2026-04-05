import Foundation
@preconcurrency import Starscream

final class OpenAIRealtimeSocket: @unchecked Sendable {
    let messages: AsyncThrowingStream<Data, Error>

    private let socket: WebSocket
    private let logPrefix: String
    private let stateQueue = DispatchQueue(label: "dev.typeflux.openai-realtime-socket")
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var messageContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var isConnected = false
    private var streamFinished = false

    init(request: URLRequest, logPrefix: String) {
        self.socket = WebSocket(request: request)
        self.logPrefix = logPrefix

        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        self.messages = AsyncThrowingStream { streamContinuation in
            continuation = streamContinuation
        }
        self.messageContinuation = continuation

        socket.callbackQueue = DispatchQueue(label: "dev.typeflux.openai-realtime-socket.callback")
        socket.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func connect(timeout: Duration) async throws {
        if stateQueue.sync(execute: { isConnected }) { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.stateQueue.sync {
                        self.connectContinuation = continuation
                    }
                    self.socket.connect()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw NSError(
                    domain: "OpenAIRealtimeSocket",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(self.logPrefix) handshake timed out."]
                )
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                disconnect()
                throw error
            }
        }
    }

    func send(text: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            socket.write(string: text) {
                continuation.resume()
            }
        }
    }

    func disconnect() {
        socket.disconnect()
    }

    private func handle(_ event: WebSocketEvent) {
        switch event {
        case .connected:
            resolveConnected()

        case .text(let text):
            messageContinuation?.yield(Data(text.utf8))

        case .binary(let data):
            messageContinuation?.yield(data)

        case .disconnected(let reason, let code):
            let error = makeCloseError(code: code, reason: reason)
            NetworkDebugLogger.logMessage(
                "\(logPrefix): WebSocket closed with code=\(code)"
                    + (reason.isEmpty ? "" : " reason=\(reason)")
            )
            failConnectionIfNeeded(error)
            finishStreamIfNeeded(error)

        case .error(let error):
            let resolved = error ?? NSError(
                domain: "OpenAIRealtimeSocket",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(logPrefix) socket error."]
            )
            failConnectionIfNeeded(resolved)
            finishStreamIfNeeded(resolved)

        case .cancelled:
            let error = NSError(
                domain: "OpenAIRealtimeSocket",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "\(logPrefix) socket cancelled."]
            )
            failConnectionIfNeeded(error)
            finishStreamIfNeeded(error)

        case .peerClosed:
            let error = NSError(
                domain: "OpenAIRealtimeSocket",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(logPrefix) socket peer closed."]
            )
            failConnectionIfNeeded(error)
            finishStreamIfNeeded(error)

        case .viabilityChanged, .reconnectSuggested, .pong, .ping:
            break

        @unknown default:
            break
        }
    }

    private func resolveConnected() {
        let continuation = stateQueue.sync { () -> CheckedContinuation<Void, Error>? in
            isConnected = true
            let continuation = connectContinuation
            connectContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func failConnectionIfNeeded(_ error: Error) {
        let continuation = stateQueue.sync { () -> CheckedContinuation<Void, Error>? in
            let continuation = connectContinuation
            connectContinuation = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    private func finishStreamIfNeeded(_ error: Error) {
        let continuation = stateQueue.sync { () -> AsyncThrowingStream<Data, Error>.Continuation? in
            guard !streamFinished else { return nil }
            streamFinished = true
            return messageContinuation
        }
        continuation?.finish(throwing: error)
    }

    private func makeCloseError(code: UInt16, reason: String) -> NSError {
        let description = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = description.isEmpty
            ? "\(logPrefix) WebSocket closed with code \(code)."
            : "\(logPrefix) WebSocket closed with code \(code): \(description)"
        return NSError(
            domain: "OpenAIRealtimeSocket",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
