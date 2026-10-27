import Darwin
import Foundation

/// Private inherited channels, with an authenticated local recovery channel for
/// chat. A stalled peer consumes one bounded request, never the caller's UI thread.
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
    private static let cancelMethod = "_cancel"
    private var wire: FeatureRPCWire
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
    private let reconnect: (@Sendable () async throws -> Int32)?
    private let onReconnected: (@Sendable () -> Void)?
    private var recovering: Task<Void, Never>?
    private var disconnected = false
    private var reconnectWaiters = 0

    init(descriptor: Int32, diagnostics: AskFailureDiagnostics = .shared,
         reconnect: (@Sendable () async throws -> Int32)? = nil,
         onReconnected: (@Sendable () -> Void)? = nil) throws {
        self.diagnostics = diagnostics
        self.reconnect = reconnect
        self.onReconnected = onReconnected
        wire = try FeatureRPCWire(descriptor: descriptor, diagnostics: diagnostics)
        writer = DispatchQueue(label: "Typeflux.feature-rpc.writer", qos: .userInitiated)
    }

    deinit { wire.stop(); reader?.cancel(); recovering?.cancel() }

    func start(handler: @escaping Handler) {
        guard reader == nil, !closed else { return }
        self.handler = handler
        startReader()
    }

    private func startReader() {
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
                    await self.receive(message, from: wire)
                }
            } catch {
                if !Task.isCancelled { diagnostics.record(.rpcRead, error: error) }
                await self?.transportFailed(wire)
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
        guard !method.isEmpty, method != Self.cancelMethod, method.utf8.count <= 128, payload.count <= FeatureRPCWire.maximumPayload,
              timeout > .zero, timeout <= .seconds(180) else { throw Failure.invalidMessage }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        if disconnected {
            guard pending.count + reconnectWaiters < 32 else {
                diagnostics.record(.rpcQueue, error: Failure.busy, reason: .requestLimit, method: method)
                throw Failure.busy
            }
            reconnectWaiters += 1
            defer { reconnectWaiters -= 1 }
            do {
                while disconnected && !closed && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch is CancellationError { throw Failure.cancelled }
        }
        guard !closed else { throw Failure.unavailable }
        guard !disconnected else { throw Failure.timedOut }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw Failure.timedOut }
        guard pending.count < 32 else {
            diagnostics.record(.rpcQueue, error: Failure.busy, reason: .requestLimit, method: method)
            throw Failure.busy
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                tickets[id] = FeatureRPCTicket()
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: remaining) } catch { return }
                    await self?.finish(id, result: .failure(Failure.timedOut), cancelRemote: true)
                }
                send(.init(version: 1, id: id, method: method, payload: payload, failure: nil))
            }
        } onCancel: { Task { await self.finish(id, result: .failure(Failure.cancelled), cancelRemote: true) } }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        recovering?.cancel(); recovering = nil
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

    #if DEBUG
    func simulateDisconnect() { wire.stop() }
    #endif

    private func transportFailed(_ failedWire: FeatureRPCWire) {
        guard !closed, wire === failedWire, !disconnected else { return }
        guard let reconnect else { stop(); return }
        disconnected = true
        failedWire.stop()
        reader?.cancel(); reader = nil
        for task in deadlines.values { task.cancel() }
        deadlines.removeAll()
        for ticket in tickets.values { ticket.cancel() }
        tickets.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: Failure.unavailable) }
        for task in incoming.values { task.cancel() }
        // Cancellation can be ignored by a handler. Keep its admission slot and
        // byte budget occupied until it really exits, even across reconnects.
        recovering = Task { [weak self] in
            var retryDelay: Duration = .milliseconds(100)
            while !Task.isCancelled {
                do {
                    let descriptor = try await reconnect()
                    guard let self else { close(descriptor); return }
                    if await self.installReconnected(descriptor) { return }
                } catch is CancellationError { return } catch {}
                do { try await Task.sleep(for: retryDelay) } catch { return }
                retryDelay = min(retryDelay * 2, .seconds(5))
            }
        }
    }

    private func installReconnected(_ descriptor: Int32) -> Bool {
        guard !closed, disconnected else { close(descriptor); return true }
        do {
            wire = try FeatureRPCWire(descriptor: descriptor, diagnostics: diagnostics)
            disconnected = false; recovering = nil
            startReader()
            onReconnected?()
            return true
        } catch { return false }
    }

    private func finish(_ id: UUID, result: Result<Data, Error>, cancelRemote: Bool = false) {
        tickets.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        // Cancellation follows the original request on the same ordered wire, including
        // forwarded calls. Keep the incoming slot occupied until its work actually exits.
        if cancelRemote, !closed, !disconnected {
            send(.init(version: 1, id: id, method: Self.cancelMethod, payload: Data(), failure: nil))
        }
        continuation.resume(with: result)
    }

    private func receive(_ message: Message, from source: FeatureRPCWire) {
        guard !closed, !disconnected, wire === source else { return }
        guard message.version == 1 else {
            diagnostics.record(.rpcProtocol, error: Failure.invalidMessage, reason: .invalidVersion)
            stop(); return
        }
        if message.method == Self.cancelMethod {
            guard message.payload?.isEmpty == true, message.failure == nil else {
                stop(); return
            }
            incoming[message.id]?.cancel()
            return
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
            await self?.reply(response, from: source, method: method)
        }
    }

    private func reply(_ message: Message, from source: FeatureRPCWire, method: String) {
        incomingBytes.removeValue(forKey: message.id)
        incoming.removeValue(forKey: message.id)
        guard wire === source, !disconnected, !closed else { return }
        if !closed { send(message, diagnosticMethod: method) }
    }

    private func send(_ message: Message, diagnosticMethod: String? = nil) {
        let count = message.payload?.count ?? 0
        guard queuedMessages < 64, queuedBytes + count <= 192 * 1024 * 1024 else {
            diagnostics.record(.rpcQueue, error: Failure.busy, reason: .queueLimit, method: message.method)
            transportFailed(wire); return
        }
        queuedMessages += 1; queuedBytes += count
        let wire = wire, diagnostics = diagnostics, ticket = message.method == nil ? nil : tickets[message.id]
        writer.async { [weak self] in
            do {
                if ticket?.isCancelled != true { try wire.send(message, diagnosticMethod: diagnosticMethod ?? message.method) }
                Task { await self?.didWrite(count) }
            } catch {
                diagnostics.record(.rpcWrite, error: error, method: diagnosticMethod ?? message.method)
                Task { await self?.didWrite(count); await self?.transportFailed(wire) }
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

    func send(_ message: FeatureRPC.Message, diagnosticMethod: String?) throws {
        guard (message.payload?.count ?? 0) <= Self.maximumPayload else { throw FeatureRPC.Failure.invalidMessage }
        let data = try JSONEncoder().encode(message)
        guard data.count <= Self.maximumFrame else { throw FeatureRPC.Failure.invalidMessage }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(data)
        try transfer(&frame, writing: true, inactivityTimeout: .seconds(5), diagnosticMethod: diagnosticMethod)
    }

    func receive() throws -> FeatureRPC.Message {
        var header = Data(count: 4)
        try transfer(&header, writing: false, inactivityTimeout: nil)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Self.maximumFrame else { throw FeatureRPC.Failure.invalidMessage }
        var payload = Data(count: Int(length))
        try transfer(&payload, writing: false, inactivityTimeout: .seconds(5))
        let message = try JSONDecoder().decode(FeatureRPC.Message.self, from: payload)
        guard (message.payload?.count ?? 0) <= Self.maximumPayload else { throw FeatureRPC.Failure.invalidMessage }
        return message
    }

    private func transfer(_ data: inout Data, writing: Bool, inactivityTimeout: Duration?, diagnosticMethod: String? = nil) throws {
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            var deadline = inactivityTimeout.map { ContinuousClock.now.advanced(by: $0) }
            // Keep a hard limit too: a peer must not hold a frame forever by
            // sending just enough data to reset the inactivity timer.
            let hardDeadline = inactivityTimeout.map { _ in ContinuousClock.now.advanced(by: .seconds(120)) }
            while offset < buffer.count {
                guard !lock.withLock({ stopped }) else { throw FeatureRPC.Failure.unavailable }
                if let deadline, ContinuousClock.now >= deadline {
                    diagnostics.record(writing ? .rpcWrite : .rpcRead, error: FeatureRPC.Failure.timedOut,
                        reason: .frameDeadline, method: diagnosticMethod, frameBytes: buffer.count, transferredBytes: offset)
                    throw FeatureRPC.Failure.timedOut
                }
                let base = buffer.baseAddress!.advanced(by: offset)
                let count = writing ? Darwin.write(descriptor, base, buffer.count - offset)
                    : Darwin.read(descriptor, base, buffer.count - offset)
                if count > 0 {
                    offset += count
                    if let inactivityTimeout, let hardDeadline {
                        deadline = min(.now.advanced(by: inactivityTimeout), hardDeadline)
                    }
                    continue
                }
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
