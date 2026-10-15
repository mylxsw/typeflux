import Foundation
import TypefluxInferenceProtocol

public protocol InferenceEngine: Sendable {
    func prepare(_ configuration: InferenceConfiguration) async throws -> String?
    func transcribe(_ request: InferenceMessage, progress: @escaping @Sendable (String) -> Bool) async throws -> String
}

/// A single engine and one request at a time. Progress has a one-element mailbox;
/// final results are sent only after the progress writer has been joined.
public final class InferenceServer: Sendable {
    private let engine: any InferenceEngine
    public init(engine: any InferenceEngine) { self.engine = engine }

    public func serve(socket: InferenceSocket) async {
        var prepared = false
        var previousID: UUID?
        do {
            while !socket.isStopped {
                let request = try socket.receive(deadline: .now.advanced(by: .seconds(86400)))
                guard request.sequence == 0, request.id != previousID else { throw InferenceFailure.protocolViolation }
                previousID = request.id
                var reply = InferenceMessage(id: request.id, kind: .ready)
                switch request.kind {
                case .probe: break
                case .prepare:
                    guard !prepared, let configuration = request.configuration else {
                        throw InferenceFailure.protocolViolation
                    }
                    reply.modelPath = try await engine.prepare(configuration)
                    prepared = true
                case .transcribe:
                    guard prepared else { throw InferenceFailure.protocolViolation }
                    let mailbox = InferenceProgressMailbox()
                    let writer = Task.detached {
                        var sequence = 1
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .milliseconds(100))
                                if let text = mailbox.take() {
                                    var partial = InferenceMessage(id: request.id, kind: .progress)
                                    partial.text = text
                                    partial.sequence = sequence
                                    sequence += 1
                                    try socket.send(partial, deadline: .now.advanced(by: .seconds(2)))
                                }
                            }
                        } catch is CancellationError { } catch { socket.stop() }
                        return sequence
                    }
                    do {
                        reply.text = try await engine.transcribe(request) { text in
                            mailbox.offer(text)
                            return !socket.isStopped
                        }
                        reply.kind = .final
                    } catch { reply.kind = .failed }
                    writer.cancel()
                    reply.sequence = await writer.value
                default: throw InferenceFailure.protocolViolation
                }
                try socket.send(reply, deadline: .now.advanced(by: .seconds(2)))
                if reply.kind == .failed { break }
            }
        } catch { /* Protocol and engine diagnostics never leave this process. */ }
        socket.stop()
    }
}

public final class InferenceProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: String?
    public init() {}
    public func offer(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 131072 else { return }
        lock.lock(); latest = text; lock.unlock()
    }
    public func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { latest = nil }
        return latest
    }
}
