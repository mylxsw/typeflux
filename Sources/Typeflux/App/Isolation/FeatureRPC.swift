import Darwin
import Foundation

/// Private inherited channels only. No listener, port, credential file or retry.
/// A stalled peer consumes one bounded request, never the caller's UI thread.
actor FeatureRPC {
    enum Failure: String, Error, Codable { case unavailable, busy, timedOut, invalidMessage, cancelled }
    struct Empty: Codable, Sendable {}
    struct Message: Codable, Sendable {
        let version: Int
        let id: UUID
        let method: String?
        let payload: Data?
        let failure: Failure?
    }
    typealias Handler = @Sendable (String, Data) async throws -> Data
    private let wire: FeatureRPCWire
    private var handler: Handler?
    private var reader: Task<Void, Never>?
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private var incoming: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    private var queuedBytes = 0
    private var queuedMessages = 0
    private var tickets: [UUID: FeatureRPCTicket] = [:]
    private var incomingBytes: [UUID: Int] = [:]
    private let writer: DispatchQueue
    private let diagnostics: AskFailureDiagnostics

    init(descriptor: Int32, diagnostics: AskFailureDiagnostics = .shared) throws {
        self.diagnostics = diagnostics
        wire = try FeatureRPCWire(descriptor: descriptor, diagnostics: diagnostics)
        writer = DispatchQueue(label: "Typeflux.feature-rpc.writer", qos: .userInitiated)
    }

    deinit { wire.stop(); reader?.cancel() }

    func start(handler: @escaping Handler) {
        guard reader == nil, !closed else { return }
        self.handler = handler
        let wire = wire, diagnostics = diagnostics
        let reads = DispatchQueue(label: "Typeflux.feature-rpc.reader", qos: .userInitiated)
        reader = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    // Blocking socket reads must never occupy Swift's shared executor.
                    let message: Message = try await withCheckedThrowingContinuation { continuation in
                        reads.async { continuation.resume(with: Result { try wire.receive() }) }
                    }
                    guard let self else { break }
                    await self.receive(message)
                }
            } catch {
                if !Task.isCancelled { diagnostics.record(.rpcRead, error: error) }
                await self?.stop()
            }
        }
    }

    func call<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ method: String, _ input: Input, timeout: Duration = .seconds(10)
    ) async throws -> Output {
        let payload = try JSONEncoder().encode(input)
        return try JSONDecoder().decode(Output.self, from: await request(method, payload: payload, timeout: timeout))
    }

    func request(_ method: String, payload: Data, timeout: Duration = .seconds(10)) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw Failure.unavailable }
        guard pending.count < 32 else {
            diagnostics.record(.rpcQueue, error: Failure.busy, reason: .requestLimit, method: method)
            throw Failure.busy
        }
        guard !method.isEmpty, method.utf8.count <= 128, payload.count <= FeatureRPCWire.maximumPayload,
              timeout > .zero, timeout <= .seconds(180) else { throw Failure.invalidMessage }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                tickets[id] = FeatureRPCTicket()
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.finish(id, result: .failure(Failure.timedOut))
                }
                send(.init(version: 1, id: id, method: method, payload: payload, failure: nil))
            }
        } onCancel: { Task { await self.finish(id, result: .failure(Failure.cancelled)) } }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        wire.stop()
        reader?.cancel(); reader = nil
        for task in deadlines.values { task.cancel() }
        deadlines.removeAll()
        for ticket in tickets.values { ticket.cancel() }
        tickets.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: Failure.unavailable) }
        for task in incoming.values { task.cancel() }
        incoming.removeAll()
        incomingBytes.removeAll()
        handler = nil
    }

    private func finish(_ id: UUID, result: Result<Data, Error>) {
        tickets.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func receive(_ message: Message) {
        guard !closed else { return }
        guard message.version == 1 else {
            diagnostics.record(.rpcProtocol, error: Failure.invalidMessage, reason: .invalidVersion)
            stop(); return
        }
        guard let method = message.method else {
            guard (message.payload == nil) != (message.failure == nil) else {
                diagnostics.record(.rpcProtocol, error: Failure.invalidMessage, reason: .malformedReply)
                stop(); return
            }
            if let failure = message.failure { finish(message.id, result: .failure(failure)) }
            else if let payload = message.payload { finish(message.id, result: .success(payload)) }
            return
        }
        guard !method.isEmpty, method.utf8.count <= 128, message.failure == nil,
              let payload = message.payload, incoming[message.id] == nil else {
            diagnostics.record(.rpcProtocol, error: Failure.invalidMessage, reason: .malformedRequest)
            stop(); return
        }
        guard incoming.count < 32, incomingBytes.values.reduce(0, +) + payload.count <= 192 * 1024 * 1024, let handler else {
            send(.init(version: 1, id: message.id, method: nil, payload: nil, failure: .busy))
            return
        }
        incomingBytes[message.id] = payload.count
        incoming[message.id] = Task { [weak self] in
            let response: Message
            do {
                let result = try await handler(method, payload)
                response = .init(version: 1, id: message.id, method: nil, payload: result, failure: nil)
            } catch {
                response = .init(version: 1, id: message.id, method: nil, payload: nil,
                                 failure: error as? Failure ?? .unavailable)
            }
            await self?.reply(response)
        }
    }

    private func reply(_ message: Message) {
        incomingBytes.removeValue(forKey: message.id)
        incoming.removeValue(forKey: message.id)
        if !closed { send(message) }
    }

    private func send(_ message: Message) {
        let count = message.payload?.count ?? 0
        guard queuedMessages < 64, queuedBytes + count <= 192 * 1024 * 1024 else {
            diagnostics.record(.rpcQueue, error: Failure.busy, reason: .queueLimit, method: message.method)
            stop(); return
        }
        queuedMessages += 1; queuedBytes += count
        let wire = wire, diagnostics = diagnostics, ticket = message.method == nil ? nil : tickets[message.id]
        writer.async { [weak self] in
            do {
                if ticket?.isCancelled != true { try wire.send(message) }
                Task { await self?.didWrite(count) }
            } catch {
                diagnostics.record(.rpcWrite, error: error, method: message.method)
                Task { await self?.didWrite(count); await self?.stop() }
            }
        }
    }

    private func didWrite(_ count: Int) { queuedMessages -= 1; queuedBytes -= count }

}

private final class FeatureRPCWire: @unchecked Sendable {
    static let maximumPayload = 128 * 1024 * 1024
    private static let maximumFrame = maximumPayload * 2
    private let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false
    private let diagnostics: AskFailureDiagnostics

    init(descriptor: Int32, diagnostics: AskFailureDiagnostics) throws {
        self.diagnostics = diagnostics
        var kind: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &kind, &size) == 0, kind == SOCK_STREAM else {
            close(descriptor); throw FeatureRPC.Failure.invalidMessage
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            close(descriptor); throw FeatureRPC.Failure.unavailable
        }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) }
    func stop() { lock.withLock { if !stopped { stopped = true; shutdown(descriptor, SHUT_RDWR) } } }

    func send(_ message: FeatureRPC.Message) throws {
        guard (message.payload?.count ?? 0) <= Self.maximumPayload else { throw FeatureRPC.Failure.invalidMessage }
        let data = try JSONEncoder().encode(message)
        guard data.count <= Self.maximumFrame else { throw FeatureRPC.Failure.invalidMessage }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        try transfer(&frame, writing: true, deadline: .now.advanced(by: .seconds(5)))
    }

    func receive() throws -> FeatureRPC.Message {
        var header = Data(count: 4)
        try transfer(&header, writing: false, deadline: nil)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Self.maximumFrame else { throw FeatureRPC.Failure.invalidMessage }
        var payload = Data(count: Int(length))
        try transfer(&payload, writing: false, deadline: .now.advanced(by: .seconds(5)))
        let message = try JSONDecoder().decode(FeatureRPC.Message.self, from: payload)
        guard (message.payload?.count ?? 0) <= Self.maximumPayload else { throw FeatureRPC.Failure.invalidMessage }
        return message
    }

    private func transfer(_ data: inout Data, writing: Bool, deadline: ContinuousClock.Instant?) throws {
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                guard !lock.withLock({ stopped }) else { throw FeatureRPC.Failure.unavailable }
                if let deadline, ContinuousClock.now >= deadline {
                    diagnostics.record(writing ? .rpcWrite : .rpcRead, error: FeatureRPC.Failure.timedOut,
                        reason: .frameDeadline)
                    throw FeatureRPC.Failure.timedOut
                }
                let base = buffer.baseAddress!.advanced(by: offset)
                let count = writing ? Darwin.write(descriptor, base, buffer.count - offset)
                    : Darwin.read(descriptor, base, buffer.count - offset)
                if count > 0 { offset += count; continue }
                guard count < 0, errno == EAGAIN || errno == EINTR else {
                    let error: any Error = count == 0 ? FeatureRPC.Failure.unavailable
                        : NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    if !lock.withLock({ stopped }) {
                        diagnostics.record(writing ? .rpcWrite : .rpcRead, error: error,
                            reason: count == 0 ? .peerClosed : .socketError)
                    }
                    throw FeatureRPC.Failure.unavailable
                }
                var item = pollfd(fd: descriptor, events: Int16(writing ? POLLOUT : POLLIN), revents: 0)
                // shutdown() wakes idle readers. Only an in-progress frame needs
                // a timeout; an empty channel must not wake every 20 ms.
                let timeout: Int32
                if let deadline {
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let milliseconds = Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15
                    timeout = Int32(max(0, min(Double(Int32.max), milliseconds.rounded(.up))))
                } else {
                    timeout = -1
                }
                guard poll(&item, 1, timeout) >= 0 || errno == EINTR else {
                    diagnostics.record(writing ? .rpcWrite : .rpcRead,
                        error: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)), reason: .socketError)
                    throw FeatureRPC.Failure.unavailable
                }
            }
        }
    }
}

private final class FeatureRPCTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
