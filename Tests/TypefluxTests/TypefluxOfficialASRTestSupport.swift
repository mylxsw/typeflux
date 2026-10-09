import Foundation
import Network
@testable import Typeflux

/// 100 ms of 16 kHz mono PCM16 silence as a WAV file.
enum ASRTestAudio {
    static func writeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typeflux-asr-boundary-\(UUID().uuidString).wav")
        let dataByteCount = 3200
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            Swift.withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + dataByteCount))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16000))
        append(UInt32(32000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(dataByteCount))
        data.append(Data(count: dataByteCount))
        try data.write(to: url)
        return url
    }
}

/// Issues a distinct grant per fetch and records the access token used. One
/// fetch can be parked at `gate` until the test releases it.
actor RecordingRoutingClient: TypefluxOfficialASRRoutingClient {
    nonisolated let gate = ParkingGate()
    private let servers: [URL]
    private let parkFetch: Int?
    private(set) var accessTokens: [String] = []

    init(servers: [URL], parkFetch: Int? = nil) {
        self.servers = servers
        self.parkFetch = parkFetch
    }

    func fetchRoute(
        accessToken: String,
        scenario _: TypefluxCloudScenario
    ) async throws -> TypefluxOfficialASRRouteDecision {
        accessTokens.append(accessToken)
        let number = accessTokens.count
        if number == parkFetch {
            // Like a real request that ignores cancellation, the grant is
            // still issued once released.
            await gate.park()
        }
        return .webSocket(
            token: "grant-\(number)",
            tokenType: "Bearer",
            expiresAt: nil,
            expiresInSeconds: 300,
            serverBaseURLs: servers
        )
    }
}

/// Why a test stopped waiting for its worker to reach a point.
enum GateWaitError: Error, Equatable {
    case timedOut
    case workerFinished
}

/// A point where a worker parks until the test releases it. A release that
/// arrives before the worker parks is kept, so the worker then passes
/// straight through instead of needing a second release.
actor ParkingGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var reached = false
    private var released = false

    var isReleased: Bool { released }

    func park() async {
        reached = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    /// Returns once a worker reached `park()`. Throws instead of returning
    /// when `worker` finished without parking, `timeout` elapses, or the
    /// waiting task is cancelled.
    func waitUntilParked(
        unlessFinished worker: (any FinishReporting)? = nil,
        timeout: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !reached {
            if worker?.isFinished == true { throw GateWaitError.workerFinished }
            guard ContinuousClock.now < deadline else { throw GateWaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

protocol FinishReporting: Sendable {
    var isFinished: Bool { get }
}

/// A worker task the test owns. It records when it finishes, so a wait can
/// end early, and `stop(releasing:)` cancels it, opens its gates and joins it.
final class OwnedWorker<Success: Sendable>: FinishReporting {
    private let task: Task<Success, Error>
    private let finished: FinishFlag

    init(_ operation: @escaping @Sendable () async throws -> Success) {
        let finished = FinishFlag()
        self.finished = finished
        task = Task {
            defer { finished.set() }
            return try await operation()
        }
    }

    var isFinished: Bool { finished.value }

    var value: Success {
        get async throws { try await task.value }
    }

    func cancel() {
        task.cancel()
    }

    func stop(releasing gates: [ParkingGate]) async {
        task.cancel()
        for gate in gates {
            await gate.release()
        }
        _ = await task.result
    }
}

private final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func set() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

actor RecordingRegistry: TypefluxASRServerProviding {
    private(set) var failures: [URL] = []

    func refreshPublicConfig() async {}

    func orderedServers(preferred: [URL]) async -> [URL] {
        preferred
    }

    func reportFailure(_ url: URL, error _: Error) async {
        failures.append(url)
    }
}

/// A WebSocket ASR gateway on 127.0.0.1 with scripted behavior.
final class LocalASRGateway: @unchecked Sendable {
    enum Behavior {
        /// Answers the stop message with a final transcript.
        case succeed(String)
        /// Sends a partial result for the first audio, then an error.
        case partialThenError
        /// Closes the connection when audio arrives, without any output.
        case closeOnAudio
        /// Sends a transcript and part of an LLM rewrite, then an error.
        case llmThenError
        /// Accepts the session and never answers.
        case hold
        /// Rejects the account for billing as soon as the session starts,
        /// then closes the connection.
        case billingStopOnStart
        /// Sends a transcript, then stops the LLM rewrite for billing.
        case transcriptThenBillingStop
        /// Accepts TCP connections and closes them before the upgrade.
        case rejectConnection
        /// Accepts TCP connections and never answers the upgrade.
        case silentTCP
    }

    private let behavior: Behavior
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var state = (connections: 0, disconnects: 0, audioBytes: 0, stop: false, stopped: false)
    private let authorizationLog: AuthorizationLog

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!
    }

    var connectionCount: Int { locked { state.connections } }
    var disconnectCount: Int { locked { state.disconnects } }
    var audioBytes: Int { locked { state.audioBytes } }
    var receivedStop: Bool { locked { state.stop } }
    var isStopped: Bool { locked { state.stopped } }
    var authorizations: [String] { authorizationLog.values }

    private init(behavior: Behavior) throws {
        self.behavior = behavior
        let queue = DispatchQueue(label: "LocalASRGateway")
        let authorizationLog = AuthorizationLog()
        self.queue = queue
        self.authorizationLog = authorizationLog
        let parameters = NWParameters.tcp
        switch behavior {
        case .rejectConnection, .silentTCP:
            break
        default:
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            webSocket.setClientRequestHandler(queue) { _, headers in
                authorizationLog.append(headers.first { $0.name.lowercased() == "authorization" }?.value ?? "")
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(behavior: Behavior) async throws -> LocalASRGateway {
        let gateway = try LocalASRGateway(behavior: behavior)
        do {
            try await gateway.listen()
        } catch {
            gateway.stop()
            throw error
        }
        return gateway
    }

    /// Starts two gateways. When the second cannot start, the first is
    /// stopped before the error is thrown.
    static func startPair(
        _ first: Behavior,
        _ second: Behavior,
        start: (Behavior) async throws -> LocalASRGateway = { try await LocalASRGateway.start(behavior: $0) }
    ) async throws -> (LocalASRGateway, LocalASRGateway) {
        let firstGateway = try await start(first)
        do {
            return try await (firstGateway, start(second))
        } catch {
            firstGateway.stop()
            throw error
        }
    }

    func stop() {
        locked { state.stopped = true }
        listener.cancel()
        locked { connections }.forEach { $0.cancel() }
    }

    private func listen() async throws {
        if case .rejectConnection = behavior {
            listener.newConnectionHandler = { [weak self] connection in
                self?.locked { self?.state.connections += 1 }
                connection.cancel()
            }
        } else {
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
        }
        let resumed = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case let .failed(error), let .waiting(error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        locked {
            state.connections += 1
            connections.append(connection)
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.locked { self?.state.disconnects += 1 }
            default:
                break
            }
        }
        connection.start(queue: queue)
        if case .silentTCP = behavior { return }
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                connection.cancel()
                return
            }
            if metadata?.opcode == .binary {
                handleAudio(data ?? Data(), on: connection)
            } else if let data, let text = String(data: data, encoding: .utf8) {
                handleText(text, on: connection)
            }
            receive(on: connection)
        }
    }

    private func handleAudio(_ data: Data, on connection: NWConnection) {
        let first = locked { () -> Bool in
            let first = state.audioBytes == 0
            state.audioBytes += data.count
            return first
        }
        guard first else { return }
        switch behavior {
        case .partialThenError:
            send(["type": "partial", "text": "hello"], on: connection)
            send(["type": "error", "code": "PROVIDER_FAILED", "error": "provider failed"], on: connection)
        case .closeOnAudio:
            connection.cancel()
        default:
            break
        }
    }

    private func handleText(_ text: String, on connection: NWConnection) {
        if case .billingStopOnStart = behavior, text.contains("\"start\"") {
            send(["type": "error", "code": "INSUFFICIENT_CREDITS", "error": "insufficient credits"], on: connection)
            queue.asyncAfter(deadline: .now() + 0.05) { connection.cancel() }
            return
        }
        guard text.contains("\"stop\"") else { return }
        locked { state.stop = true }
        switch behavior {
        case let .succeed(transcript):
            send(["type": "final", "text": transcript], on: connection)
            send(["type": "event", "text": "completed"], on: connection)
        case .transcriptThenBillingStop:
            send(["type": "final", "text": "hello"], on: connection)
            send(["type": "event", "text": "completed"], on: connection)
            send(["type": "error", "code": "INSUFFICIENT_CREDITS", "error": "insufficient credits"], on: connection)
        case .llmThenError:
            send(["type": "final", "text": "hello"], on: connection)
            send(["type": "event", "text": "completed"], on: connection)
            send(["type": "llm_start"], on: connection)
            send(["type": "llm_chunk", "text": "Hel"], on: connection)
            send(["type": "error", "code": "LLM_FAILED", "error": "llm failed"], on: connection)
        default:
            break
        }
    }

    private func send(_ message: [String: String], on connection: NWConnection) {
        let data = try? JSONSerialization.data(withJSONObject: message)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in }
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class AuthorizationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func append(_ value: String) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
